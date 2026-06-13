import ADCAtomics
import Darwin

/// Cross-process reader registry + writer exclusion, living in the lock file
/// (`<db>-lock`, mapped shared).
///
/// Layout: 128 B header (magic, version, slotCount), then 126 slots of
/// 128 B (cache-line padded). Slot: ownerPid u64 (atomic; 0 = free) at +0,
/// generation u64 (atomic; 0 = no active read txn) at +8.
///
/// Each Database handle claims one slot at open (CAS on ownerPid) and
/// publishes the *minimum* generation of its in-process readers there. The
/// writer takes min over live slots before harvesting. Registration races
/// are benign by construction: a registering reader can only hold the
/// current committed generation, and reclamation lags one generation behind
/// it (`Meta.reclaimLimit`).
///
/// Writer exclusion: an fcntl(F_SETLK) write lock on header byte 0 held for
/// the life of a read-write handle. Stale readers (dead pids) are swept by
/// the writer at transaction start.
@safe final class ReaderTable: @unchecked Sendable {
  private let fd: Int32
  private let base: UnsafeMutableRawPointer
  private(set) var slotIndex: Int = -1
  private var holdsWriterLock = false

  enum SlotOffset {
    static let ownerPid = 0
    static let generation = 8
  }

  init(databasePath: String, claimWriterLock: Bool) throws(DBError) {
    let path = databasePath + "-lock"
    let fd = path.withCString { unsafe open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o644) }
    guard fd >= 0 else { try throwErrno("open(\(path))") }
    self.fd = fd

    var st = stat()
    guard unsafe fstat(fd, &st) == 0 else {
      close(fd)
      try throwErrno("fstat(lock)")
    }
    if st.st_size < off_t(Format.lockFileSize) {
      guard ftruncate(fd, off_t(Format.lockFileSize)) == 0 else {
        close(fd)
        try throwErrno("ftruncate(lock)")
      }
    }
    let mapped = unsafe mmap(nil, Format.lockFileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    guard let mapped = unsafe mapped, unsafe mapped != MAP_FAILED else {
      close(fd)
      try throwErrno("mmap(lock)")
    }
    unsafe self.base = unsafe mapped

    // Header magic (idempotent across processes).
    let headerMagic = unsafe base.load(fromByteOffset: 0, as: UInt64.self)
    if headerMagic == 0 {
      Format.lockMagicBytes.withUnsafeBytes { magic in
        unsafe base.copyMemory(from: magic.baseAddress!, byteCount: 8)
      }
      unsafe base.storeBytes(of: UInt32(1).littleEndian, toByteOffset: 8, as: UInt32.self)
      unsafe base.storeBytes(
        of: UInt32(Format.readerSlotCount).littleEndian, toByteOffset: 12, as: UInt32.self)
    }

    if claimWriterLock {
      var lock = flock(
        l_start: 0, l_len: 1, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
      if unsafe fcntl(fd, F_SETLK, &lock) == -1 {
        var probe = lock
        _ = unsafe fcntl(fd, F_GETLK, &probe)
        let holder = probe.l_pid
        unsafe munmap(base, Format.lockFileSize)
        close(fd)
        throw DBError.writerLockHeld(byPid: holder)
      }
      holdsWriterLock = true
    }

    // Reclaim slots left by crashed processes before claiming our own, so a
    // pure read-only deployment (which never runs the writer-side sweep) can't
    // be locked out by stale slots after a crash.
    sweepStaleSlots()
    try claimSlot()
  }

  deinit {
    releaseSlot()
    unsafe munmap(base, Format.lockFileSize)
    close(fd) // also drops the fcntl lock
  }

  // MARK: - Slot management

  @inline(__always)
  private func slotPointer(_ index: Int, _ field: Int) -> UnsafeMutableRawPointer {
    unsafe base + Format.lockHeaderSize + index * Format.readerSlotSize + field
  }

  private func claimSlot() throws(DBError) {
    let pid = UInt64(getpid())
    // Unique per handle: pid in the low bits, a per-process nonce above —
    // several handles in one process claim distinct slots.
    let owner = pid | (UInt64.random(in: 1...0xFFFF) << 40)
    for index in 0..<Format.readerSlotCount {
      let pidPtr = unsafe slotPointer(index, SlotOffset.ownerPid)
      if unsafe adc_load_acquire_u64(pidPtr) == 0,
        unsafe adc_cas_acq_rel_u64(pidPtr, 0, owner) {
        unsafe adc_store_release_u64(slotPointer(index, SlotOffset.generation), 0)
        slotIndex = index
        return
      }
    }
    throw DBError.readerSlotsExhausted
  }

  private func releaseSlot() {
    guard slotIndex >= 0 else { return }
    unsafe adc_store_release_u64(slotPointer(slotIndex, SlotOffset.generation), 0)
    unsafe adc_store_release_u64(slotPointer(slotIndex, SlotOffset.ownerPid), 0)
    slotIndex = -1
  }

  /// Publishes this handle's minimum active reader generation (0 = none).
  func publish(minGeneration: UInt64) {
    guard slotIndex >= 0 else { return }
    unsafe adc_store_release_u64(slotPointer(slotIndex, SlotOffset.generation), minGeneration)
  }

  /// Minimum generation across every live slot (any process), or nil when
  /// no reader is registered anywhere.
  func minimumGeneration() -> UInt64? {
    var minimum: UInt64?
    for index in 0..<Format.readerSlotCount {
      guard unsafe adc_load_acquire_u64(slotPointer(index, SlotOffset.ownerPid)) != 0 else { continue }
      let generation = unsafe adc_load_acquire_u64(slotPointer(index, SlotOffset.generation))
      guard generation != 0 else { continue }
      if minimum == nil || generation < minimum! { minimum = generation }
    }
    return minimum
  }

  /// Clears slots owned by dead processes (kill(pid, 0) == ESRCH).
  func sweepStaleSlots() {
    for index in 0..<Format.readerSlotCount {
      let pidPtr = unsafe slotPointer(index, SlotOffset.ownerPid)
      let owner = unsafe adc_load_acquire_u64(pidPtr)
      guard owner != 0 else { continue }
      let pid = pid_t(truncatingIfNeeded: owner & 0xFF_FFFF_FFFF)
      if kill(pid, 0) == -1 && errno == ESRCH {
        unsafe adc_store_release_u64(slotPointer(index, SlotOffset.generation), 0)
        _ = unsafe adc_cas_acq_rel_u64(pidPtr, owner, 0)
      }
    }
  }
}

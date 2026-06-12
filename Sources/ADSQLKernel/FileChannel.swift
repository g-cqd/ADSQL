import Darwin
import Synchronization

/// POSIX-backed storage channel. All calls are stateless per-fd operations
/// (`pread`/`pwrite`/`fcntl`), safe to issue from any thread.
public final class FileChannel: StorageChannel, @unchecked Sendable {
  public let fileDescriptor: Int32
  private let closeOnDeinit: Bool
  /// Guards against double-close: a second close() on a recycled descriptor
  /// number would tear down an unrelated file out from under another thread.
  private let closed = Atomic<Bool>(false)

  public enum Mode: Sendable {
    case readOnly
    case readWrite(create: Bool)
  }

  public init(path: String, mode: Mode) throws(DBError) {
    var flags: Int32
    switch mode {
    case .readOnly:
      flags = O_RDONLY | O_CLOEXEC
    case .readWrite(let create):
      flags = O_RDWR | O_CLOEXEC
      if create { flags |= O_CREAT }
    }
    let fd = path.withCString { open($0, flags, 0o644) }
    guard fd >= 0 else { try throwErrno("open(\(path))") }
    self.fileDescriptor = fd
    self.closeOnDeinit = true
  }

  /// Wraps an already-open descriptor (ownership not transferred).
  public init(borrowing fd: Int32) {
    self.fileDescriptor = fd
    self.closeOnDeinit = false
  }

  deinit {
    if closeOnDeinit { close() }
  }

  public func fileSize() throws(DBError) -> Int {
    var st = stat()
    guard fstat(fileDescriptor, &st) == 0 else { try throwErrno("fstat") }
    return Int(st.st_size)
  }

  public func pread(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws(DBError) {
    var done = 0
    while done < buffer.count {
      let n = Darwin.pread(
        fileDescriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
      if n < 0 {
        if errno == EINTR { continue }
        try throwErrno("pread")
      }
      if n == 0 { throw DBError.io(errno: 0, op: "pread(short read at \(offset + done))") }
      done += n
    }
  }

  public func pwrite(_ buffer: UnsafeRawBufferPointer, at offset: Int) throws(DBError) {
    var done = 0
    while done < buffer.count {
      let n = Darwin.pwrite(
        fileDescriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
      if n < 0 {
        if errno == EINTR { continue }
        try throwErrno("pwrite")
      }
      done += n
    }
  }

  public func pwritev(_ buffers: [UnsafeRawBufferPointer], at offset: Int) throws(DBError) {
    var at = offset
    var index = 0
    while index < buffers.count {
      let count = min(buffers.count - index, Int(IOV_MAX))
      let batch = buffers[index..<(index + count)]
      let total = batch.reduce(0) { $0 + $1.count }
      var iov = batch.map { buf in
        iovec(
          iov_base: UnsafeMutableRawPointer(mutating: buf.baseAddress),
          iov_len: buf.count)
      }
      let n = iov.withUnsafeMutableBufferPointer { ptr in
        Darwin.pwritev(fileDescriptor, ptr.baseAddress, Int32(count), off_t(at))
      }
      if n < 0 {
        if errno == EINTR { continue }
        try throwErrno("pwritev")
      }
      if n != total {
        // Partial vectored write: finish the remainder element-wise.
        var skip = n
        var resumeAt = at + n
        for buf in batch {
          if skip >= buf.count {
            skip -= buf.count
            continue
          }
          let rest = UnsafeRawBufferPointer(rebasing: buf[skip...])
          try pwrite(rest, at: resumeAt)
          resumeAt += rest.count
          skip = 0
        }
      }
      at += total
      index += count
    }
  }

  public func sync(_ profile: DurabilityProfile) throws(DBError) {
    switch profile {
    case .none:
      return
    case .barrier:
      if fcntl(fileDescriptor, F_BARRIERFSYNC) == -1 {
        guard fsync(fileDescriptor) == 0 else { try throwErrno("fsync(barrier fallback)") }
      }
    case .full:
      if fcntl(fileDescriptor, F_FULLFSYNC) == -1 {
        guard fsync(fileDescriptor) == 0 else { try throwErrno("fsync(full fallback)") }
      }
    }
  }

  public func preallocate(minimumSize: Int) throws(DBError) {
    let current = try fileSize()
    guard minimumSize > current else { return }
    var store = fstore_t(
      fst_flags: UInt32(F_ALLOCATECONTIG),
      fst_posmode: F_PEOFPOSMODE,
      fst_offset: 0,
      fst_length: off_t(minimumSize - current),
      fst_bytesalloc: 0)
    if fcntl(fileDescriptor, F_PREALLOCATE, &store) == -1 {
      store.fst_flags = UInt32(F_ALLOCATEALL)
      // Best effort: a failed preallocation only costs contiguity, not correctness.
      _ = fcntl(fileDescriptor, F_PREALLOCATE, &store)
    }
    guard ftruncate(fileDescriptor, off_t(minimumSize)) == 0 else { try throwErrno("ftruncate") }
  }

  public func truncate(to size: Int) throws(DBError) {
    guard ftruncate(fileDescriptor, off_t(size)) == 0 else { try throwErrno("ftruncate") }
  }

  /// Toggles the unified-buffer-cache bypass for bulk load paths.
  public func setNoCache(_ enabled: Bool) {
    _ = fcntl(fileDescriptor, F_NOCACHE, enabled ? 1 : 0)
  }

  public func close() {
    guard fileDescriptor >= 0 else { return }
    let (exchanged, _) = closed.compareExchange(
      expected: false, desired: true, ordering: .acquiringAndReleasing)
    if exchanged { _ = Darwin.close(fileDescriptor) }
  }
}

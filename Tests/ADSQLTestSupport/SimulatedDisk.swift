import ADSQLKernel
import Synchronization

/// Storage channel that journals every mutation while writing through to a
/// real file (so the engine's mmap reads still work mid-test), and can
/// materialize "power cut" images honoring barrier ordering:
///
/// - Writes are tagged with a *group*; `sync(.barrier)` and `sync(.full)`
///   close the current group (ordering boundary).
/// - `sync(.full)` additionally pins the durable floor: a crash can never
///   lose groups at or below it.
/// - A crash picks a cut group in `[durableFloor, currentGroup]`: earlier
///   groups apply fully, the cut group applies per 4 KiB sub-block at random
///   (writeback may reorder *within* barrier groups, never across), later
///   groups vanish.
public final class SimulatedDisk: StorageChannel, @unchecked Sendable {
  enum Mutation {
    case write(offset: Int, bytes: [UInt8])
    case setSize(Int)
  }
  struct Record {
    var mutation: Mutation
    var group: Int
  }
  struct State {
    var records: [Record] = []
    var currentGroup = 0
    var durableFloor = 0
  }

  private let inner: FileChannel
  private let state = Mutex(State())

  public var fileDescriptor: Int32 { inner.fileDescriptor }

  public init(path: String) throws(DBError) {
    self.inner = try FileChannel(path: path, mode: .readWrite(create: true))
    try inner.truncate(to: 0)
  }

  // MARK: - StorageChannel

  public func fileSize() throws(DBError) -> Int { try inner.fileSize() }

  public func pread(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws(DBError) {
    try inner.pread(into: buffer, at: offset)
  }

  public func pwrite(_ buffer: UnsafeRawBufferPointer, at offset: Int) throws(DBError) {
    state.withLock {
      $0.records.append(.init(mutation: .write(offset: offset, bytes: [UInt8](buffer)), group: $0.currentGroup))
    }
    try inner.pwrite(buffer, at: offset)
  }

  public func pwritev(_ buffers: [UnsafeRawBufferPointer], at offset: Int) throws(DBError) {
    var at = offset
    for buffer in buffers {
      try pwrite(buffer, at: at)
      at += buffer.count
    }
  }

  public func sync(_ profile: DurabilityProfile) throws(DBError) {
    state.withLock {
      switch profile {
      case .none:
        break
      case .barrier:
        $0.currentGroup += 1
      case .full:
        $0.currentGroup += 1
        $0.durableFloor = $0.currentGroup
      }
    }
    // No real fsync: tests never rely on actual disk durability.
  }

  public func preallocate(minimumSize: Int) throws(DBError) {
    let current = try inner.fileSize()
    if minimumSize > current {
      state.withLock {
        $0.records.append(.init(mutation: .setSize(minimumSize), group: $0.currentGroup))
      }
    }
    try inner.preallocate(minimumSize: minimumSize)
  }

  public func truncate(to size: Int) throws(DBError) {
    state.withLock {
      $0.records.append(.init(mutation: .setSize(size), group: $0.currentGroup))
    }
    try inner.truncate(to: size)
  }

  public func close() { inner.close() }

  // MARK: - Crash materialization

  public var crashCutGroups: ClosedRange<Int> {
    state.withLock { $0.durableFloor...$0.currentGroup }
  }

  /// Builds the post-power-cut file image for a random cut group drawn from
  /// `crashCutGroups`.
  public func materializeCrashImage(seed: UInt64) -> [UInt8] {
    var rng = SplitMix64(seed: seed)
    let range = crashCutGroups
    let cut = range.lowerBound + Int(rng.next() % UInt64(range.count))
    return materializeCrashImage(cutGroup: cut, tearSeed: rng.next())
  }

  public func materializeCrashImage(cutGroup: Int, tearSeed: UInt64) -> [UInt8] {
    var rng = SplitMix64(seed: tearSeed)
    var image: [UInt8] = []
    var logicalSize = 0

    func ensure(_ size: Int) {
      if image.count < size { image.append(contentsOf: repeatElement(0, count: size - image.count)) }
    }
    func apply(offset: Int, bytes: ArraySlice<UInt8>) {
      ensure(offset + bytes.count)
      image.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
      logicalSize = max(logicalSize, offset + bytes.count)
    }

    let records = state.withLock { $0.records }
    for record in records {
      if record.group > cutGroup { break }
      let keepWhole = record.group < cutGroup
      switch record.mutation {
      case .setSize(let size):
        if keepWhole || rng.next() % 2 == 0 {
          ensure(size)
          if size < image.count { image.removeSubrange(size...) }
          logicalSize = size
        }
      case .write(let offset, let bytes):
        if keepWhole {
          apply(offset: offset, bytes: bytes[...])
          continue
        }
        // Torn write: keep each 4 KiB sub-block independently.
        var sub = 0
        while sub < bytes.count {
          let end = min(sub + Format.subBlockSize, bytes.count)
          if rng.next() % 2 == 0 {
            apply(offset: offset + sub, bytes: bytes[sub..<end])
          }
          sub = end
        }
      }
    }
    ensure(logicalSize)
    return image
  }

  /// Writes a crash image to `path` so it can be reopened as a real database.
  public func writeCrashImage(_ image: [UInt8], to path: String) throws(DBError) {
    let out = try FileChannel(path: path, mode: .readWrite(create: true))
    defer { out.close() }
    try out.truncate(to: 0)
    var failure: DBError?
    image.withUnsafeBytes { raw in
      do throws(DBError) {
        try out.pwrite(raw, at: 0)
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
  }
}

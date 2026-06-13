/// Abstraction over the file the engine writes through. Production uses
/// `FileChannel`; crash-injection tests substitute a journaling channel that
/// can materialize torn power-cut images.
///
/// Reads in normal operation go through the shared mmap, not this protocol;
/// `pread` exists for the `.pread` read path (escape hatch + differential
/// oracle) and for tooling.
public protocol StorageChannel: AnyObject, Sendable {
  /// File descriptor of the real on-disk file (used for mmap).
  var fileDescriptor: Int32 { get }

  func fileSize() throws(DBError) -> Int
  func pread(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws(DBError)
  func pwrite(_ buffer: UnsafeRawBufferPointer, at offset: Int) throws(DBError)
  /// Writes `buffers` contiguously starting at `offset` (gather write).
  func pwritev(_ buffers: [UnsafeRawBufferPointer], at offset: Int) throws(DBError)
  func sync(_ profile: DurabilityProfile) throws(DBError)
  /// Ensures the file is at least `minimumSize` bytes long, preallocating
  /// contiguous space where the filesystem permits.
  func preallocate(minimumSize: Int) throws(DBError)
  func truncate(to size: Int) throws(DBError)
  func close()
}

extension StorageChannel {
  /// Byte-array convenience over `pwrite`.
  ///
  /// Note: implemented with an error capture instead of a typed-throws
  /// closure because converting a `throws(DBError)` closure over
  /// `UnsafeRawBufferPointer` to `rethrows` crashes the Swift 6.4 frontend
  /// (SILGenCleanup: "Illegal convention for non-address types").
  public func pwrite(_ bytes: [UInt8], at offset: Int) throws(DBError) {
    var failure: DBError?
    bytes.withUnsafeBytes { raw in
      do throws(DBError) {
        unsafe try pwrite(raw, at: offset)
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
  }

  /// Byte-array convenience over `pread`.
  public func preadBytes(count: Int, at offset: Int) throws(DBError) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    var failure: DBError?
    out.withUnsafeMutableBytes { raw in
      do throws(DBError) {
        unsafe try pread(into: raw, at: offset)
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
    return out
  }
}

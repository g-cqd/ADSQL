import Darwin

/// Read-only shared mapping of the database file.
///
/// The full maximum map size is reserved once at open — virtual address
/// reservation is free, macOS has no `mremap`, and the file simply grows
/// underneath the mapping (pages become valid as the file is extended, no
/// remap needed). Readers never touch pages past the committed `pageCount`,
/// so they can never fault past EOF in correct operation.
///
/// The database file is never truncated while mapped (free pages are recycled
/// instead; compaction is an offline copy), which is what makes handing out
/// borrowed views of mapped pages sound.
@safe public final class MMap: @unchecked Sendable {
  /// The naked mapping pointer is private: callers get only the bounded
  /// `pageBytes`/`bytes` views, so the unsafe pointer never leaves this type
  /// (Review 0001 F3).
  private let base: UnsafeRawPointer
  public let capacity: Int

  public init(fileDescriptor: Int32, capacity: Int) throws(DBError) {
    let ptr = unsafe mmap(nil, capacity, PROT_READ, MAP_SHARED, fileDescriptor, 0)
    guard let ptr = unsafe ptr, unsafe ptr != MAP_FAILED else { try throwErrno("mmap(\(capacity))") }
    unsafe self.base = UnsafeRawPointer(ptr)
    self.capacity = capacity
    // B+tree descent is random access; don't let read-ahead pollute the cache.
    _ = unsafe madvise(UnsafeMutableRawPointer(mutating: ptr), capacity, MADV_RANDOM)
  }

  deinit {
    _ = unsafe munmap(UnsafeMutableRawPointer(mutating: base), capacity)
  }

  /// Borrowed view of one page. The caller must guarantee `pageNo` lies
  /// within the committed file (enforced by reading only via a transaction's
  /// meta snapshot).
  @inline(__always)
  public func pageBytes(_ pageNo: UInt64) -> UnsafeRawBufferPointer {
    let offset = Int(pageNo) * Format.pageSize
    return unsafe UnsafeRawBufferPointer(start: base + offset, count: Format.pageSize)
  }

  @inline(__always)
  public func bytes(at offset: Int, count: Int) -> UnsafeRawBufferPointer {
    unsafe UnsafeRawBufferPointer(start: base + offset, count: count)
  }
}

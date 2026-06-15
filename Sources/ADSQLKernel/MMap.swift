#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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

    /// Advisory readahead for a contiguous run of `count` pages starting at
    /// `fromPage`. `MADV_WILLNEED` only schedules a prefetch for the named range
    /// — unlike `MADV_SEQUENTIAL` it does not change the mapping's global policy,
    /// so a scan can prefetch ahead without disturbing concurrent point-get
    /// readers (who keep the `MADV_RANDOM` default). Out-of-range tails are
    /// clamped to the reserved capacity; the run beyond EOF is harmless (those
    /// pages are simply not resident yet and never get touched in correct use).
    @inline(__always)
    public func prefetch(fromPage: UInt64, count: Int) {
        let start = Int(fromPage) * Format.pageSize
        guard start < capacity, count > 0 else { return }
        let length = min(count * Format.pageSize, capacity - start)
        _ = unsafe madvise(UnsafeMutableRawPointer(mutating: base + start), length, MADV_WILLNEED)
    }

    @inline(__always)
    public func bytes(at offset: Int, count: Int) -> UnsafeRawBufferPointer {
        unsafe UnsafeRawBufferPointer(start: base + offset, count: count)
    }
}

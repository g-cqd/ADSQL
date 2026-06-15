import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// POSIX-backed storage channel. All calls are stateless per-fd operations
/// (`pread`/`pwrite`/`fcntl`), safe to issue from any thread.
package final class FileChannel: StorageChannel, @unchecked Sendable {
    package let fileDescriptor: Int32
    private let closeOnDeinit: Bool
    /// Guards against double-close: a second close() on a recycled descriptor
    /// number would tear down an unrelated file out from under another thread.
    private let closed = Atomic<Bool>(false)

    package enum Mode: Sendable {
        case readOnly
        case readWrite(create: Bool)
    }

    package init(path: String, mode: Mode) throws(DBError) {
        var flags: Int32
        switch mode {
        case .readOnly:
            flags = O_RDONLY | O_CLOEXEC
        case .readWrite(let create):
            flags = O_RDWR | O_CLOEXEC
            if create { flags |= O_CREAT }
        }
        let fd = path.withCString { unsafe open($0, flags, 0o644) }
        guard fd >= 0 else { try throwErrno("open(\(path))") }
        self.fileDescriptor = fd
        self.closeOnDeinit = true
    }

    /// Wraps an already-open descriptor (ownership not transferred).
    package init(borrowing fd: Int32) {
        self.fileDescriptor = fd
        self.closeOnDeinit = false
    }

    deinit {
        if closeOnDeinit { close() }
    }

    package func fileSize() throws(DBError) -> Int {
        var st = stat()
        guard unsafe fstat(fileDescriptor, &st) == 0 else { try throwErrno("fstat") }
        return Int(st.st_size)
    }

    package func pread(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws(DBError) {
        var done = 0
        while done < buffer.count {
            // Module-qualified to disambiguate the libc syscall from this type's own
            // `pread` method; the module name is the only thing that differs by platform.
            #if canImport(Darwin)
                let n = unsafe Darwin.pread(
                    fileDescriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
            #else
                let n = unsafe Glibc.pread(
                    fileDescriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
            #endif
            if n < 0 {
                if errno == EINTR { continue }
                try throwErrno("pread")
            }
            if n == 0 { throw DBError.io(errno: 0, op: "pread(short read at \(offset + done))") }
            done += n
        }
    }

    package func pwrite(_ buffer: UnsafeRawBufferPointer, at offset: Int) throws(DBError) {
        var done = 0
        while done < buffer.count {
            #if canImport(Darwin)
                let n = unsafe Darwin.pwrite(
                    fileDescriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
            #else
                let n = unsafe Glibc.pwrite(
                    fileDescriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
            #endif
            if n < 0 {
                if errno == EINTR { continue }
                try throwErrno("pwrite")
            }
            done += n
        }
    }

    package func pwritev(_ buffers: [UnsafeRawBufferPointer], at offset: Int) throws(DBError) {
        var at = offset
        var index = 0
        while unsafe index < buffers.count {
            let count = unsafe min(buffers.count - index, Int(IOV_MAX))
            let batch = unsafe buffers[index..<(index + count)]
            let total = unsafe batch.reduce(0) { $0 + $1.count }
            var iov = unsafe batch.map { buf in
                unsafe iovec(
                    iov_base: UnsafeMutableRawPointer(mutating: buf.baseAddress),
                    iov_len: buf.count)
            }
            let n = iov.withUnsafeMutableBufferPointer { ptr in
                #if canImport(Darwin)
                    unsafe Darwin.pwritev(fileDescriptor, ptr.baseAddress, Int32(count), off_t(at))
                #else
                    unsafe Glibc.pwritev(fileDescriptor, ptr.baseAddress, Int32(count), off_t(at))
                #endif
            }
            if n < 0 {
                if errno == EINTR { continue }
                try throwErrno("pwritev")
            }
            if n != total {
                // Partial vectored write: finish the remainder element-wise.
                var skip = n
                var resumeAt = at + n
                for j in index..<(index + count) {
                    let buf = unsafe buffers[j]
                    if skip >= buf.count {
                        skip -= buf.count
                        continue
                    }
                    let rest = unsafe UnsafeRawBufferPointer(rebasing: buf[skip...])
                    unsafe try pwrite(rest, at: resumeAt)
                    resumeAt += rest.count
                    skip = 0
                }
            }
            at += total
            index += count
        }
    }

    package func sync(_ profile: DurabilityProfile) throws(DBError) {
        switch profile {
        case .none:
            return
        case .barrier:
            #if canImport(Darwin)
                if fcntl(fileDescriptor, F_BARRIERFSYNC) == -1 {
                    guard fsync(fileDescriptor) == 0 else { try throwErrno("fsync(barrier fallback)") }
                }
            #else
                // Linux has no `F_BARRIERFSYNC`. `fdatasync` is the closest analogue:
                // it forces the data (and the size metadata needed to read it back)
                // to the storage stack, which is the ordering guarantee the barrier
                // profile relies on. It does not issue a device cache flush — that is
                // exactly the barrier/full distinction Darwin draws.
                guard fdatasync(fileDescriptor) == 0 else { try throwErrno("fdatasync(barrier)") }
            #endif
        case .full:
            #if canImport(Darwin)
                if fcntl(fileDescriptor, F_FULLFSYNC) == -1 {
                    guard fsync(fileDescriptor) == 0 else { try throwErrno("fsync(full fallback)") }
                }
            #else
                // `F_FULLFSYNC` asks the drive to flush its cache; Linux exposes no
                // portable userspace equivalent, so `fsync` is the strongest portable
                // guarantee (already the Darwin fallback when `F_FULLFSYNC` is refused).
                guard fsync(fileDescriptor) == 0 else { try throwErrno("fsync(full)") }
            #endif
        }
    }

    package func preallocate(minimumSize: Int) throws(DBError) {
        let current = try fileSize()
        guard minimumSize > current else { return }
        #if canImport(Darwin)
            var store = fstore_t(
                fst_flags: UInt32(F_ALLOCATECONTIG),
                fst_posmode: F_PEOFPOSMODE,
                fst_offset: 0,
                fst_length: off_t(minimumSize - current),
                fst_bytesalloc: 0)
            if unsafe fcntl(fileDescriptor, F_PREALLOCATE, &store) == -1 {
                store.fst_flags = UInt32(F_ALLOCATEALL)
                // Best effort: a failed preallocation only costs contiguity, not correctness.
                _ = unsafe fcntl(fileDescriptor, F_PREALLOCATE, &store)
            }
        #else
            // Linux equivalent: `posix_fallocate` reserves backing blocks for the
            // range. Like the Darwin `F_PREALLOCATE` hint it is a best-effort
            // optimization (avoids fragmentation / ENOSPC-at-write), not a
            // correctness requirement — the shared `ftruncate` below establishes the
            // actual file length post-condition. On filesystems that don't support it
            // `posix_fallocate` returns an error code, which we ignore.
            _ = posix_fallocate(fileDescriptor, off_t(current), off_t(minimumSize - current))
        #endif
        guard ftruncate(fileDescriptor, off_t(minimumSize)) == 0 else { try throwErrno("ftruncate") }
    }

    package func truncate(to size: Int) throws(DBError) {
        guard ftruncate(fileDescriptor, off_t(size)) == 0 else { try throwErrno("ftruncate") }
    }

    /// Toggles the unified-buffer-cache bypass for bulk load paths.
    package func setNoCache(_ enabled: Bool) {
        #if canImport(Darwin)
            _ = fcntl(fileDescriptor, F_NOCACHE, enabled ? 1 : 0)
        #else
            // Linux has no persistent per-fd "no cache" mode. The closest best-effort
            // is to advise the page cache to drop this file's pages when bypass is
            // requested (`POSIX_FADV_DONTNEED` over the whole file, len 0 = to EOF),
            // and to restore the default policy otherwise. Purely advisory: any error
            // (e.g. ENOSYS on exotic filesystems) is ignored, exactly like the Darwin
            // `fcntl` whose result is discarded.
            _ = posix_fadvise(
                fileDescriptor, 0, 0, enabled ? POSIX_FADV_DONTNEED : POSIX_FADV_NORMAL)
        #endif
    }

    package func close() {
        guard fileDescriptor >= 0 else { return }
        let (exchanged, _) = closed.compareExchange(
            expected: false, desired: true, ordering: .acquiringAndReleasing)
        // Module-qualified to call the libc syscall, not this type's `close()`.
        #if canImport(Darwin)
            if exchanged { _ = Darwin.close(fileDescriptor) }
        #else
            if exchanged { _ = Glibc.close(fileDescriptor) }
        #endif
    }
}

package import ADSQLKernel

/// Vectored-write test helper: copies each chunk into stable heap buffers so
/// the gather path of `pwritev` is exercised without escaping `withUnsafeBytes`
/// pointers (and without typed-throws closures, which crash the 6.4 frontend
/// when reabstracted — see StorageChannel.pwrite(_:at:)).
package func pwritevCopied(
    _ channel: some StorageChannel, _ chunks: [[UInt8]], at offset: Int
) throws(DBError) {
    var buffers: [UnsafeMutableRawBufferPointer] = []
    defer { for b in buffers { b.deallocate() } }
    for chunk in chunks {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk.count, alignment: 16)
        buffer.copyBytes(from: chunk)
        buffers.append(buffer)
    }
    try channel.pwritev(buffers.map { UnsafeRawBufferPointer($0) }, at: offset)
}

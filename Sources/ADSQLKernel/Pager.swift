/// Production page source: committed pages served zero-copy from the shared
/// mapping. Correctness of bounds comes from reading only page numbers
/// reachable from a committed meta (pages `[0, meta.pageCount)` always lie
/// within the file).
public final class Pager: PageSource, @unchecked Sendable {
  public let channel: any StorageChannel
  public let map: MMap

  public init(channel: any StorageChannel, maxMapSize: Int) throws(DBError) {
    self.channel = channel
    self.map = try MMap(fileDescriptor: channel.fileDescriptor, capacity: maxMapSize)
  }

  @inline(__always)
  public func page(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
    let end = (Int(pageNo) + 1) * Format.pageSize
    guard end <= map.capacity else { throw DBError.mapFull }
    return unsafe map.pageBytes(pageNo)
  }
}

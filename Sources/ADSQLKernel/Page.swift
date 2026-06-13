/// Node page header codec and slotted-page primitives.
///
/// Header (32 bytes):
///   0–7   XXH64 over bytes 8..<16384, seeded with the page number
///   8     page type (branch / leaf / overflow / freelist)
///   9     flags (reserved)
///   10–11 cellCount — for overflow pages: dataLen
///   12–13 cellAreaStart (cell content grows down from the page end)
///   14–15 fragmentedBytes (dead bytes inside the cell area)
///   16–23 branch: leftmostChild · overflow: nextOverflowPage · else 0
///   24–31 reserved
///
/// After the header comes the slot array (u16 cell offsets, key-sorted,
/// growing up) and, from the end of the page growing down, the cells.
public enum PageHeader {
  public enum Offset {
    public static let checksum = 0
    public static let pageType = 8
    public static let flags = 9
    public static let cellCount = 10
    public static let cellAreaStart = 12
    public static let fragmentedBytes = 14
    public static let link = 16
    public static let reserved = 24
  }

  // MARK: Reads

  @inline(__always)
  public static func pageType(_ page: UnsafeRawBufferPointer) -> PageType? {
    unsafe PageType(rawValue: page[Offset.pageType])
  }
  @inline(__always)
  public static func cellCount(_ page: UnsafeRawBufferPointer) -> Int {
    unsafe Int(page.loadLE16(Offset.cellCount))
  }
  @inline(__always)
  public static func cellAreaStart(_ page: UnsafeRawBufferPointer) -> Int {
    unsafe Int(page.loadLE16(Offset.cellAreaStart))
  }
  @inline(__always)
  public static func fragmentedBytes(_ page: UnsafeRawBufferPointer) -> Int {
    unsafe Int(page.loadLE16(Offset.fragmentedBytes))
  }
  /// Branch: leftmost child. Overflow: next page in the chain (0 = end).
  @inline(__always)
  public static func link(_ page: UnsafeRawBufferPointer) -> UInt64 {
    unsafe page.loadLE64(Offset.link)
  }
  /// Overflow pages reuse the cellCount field as their payload length.
  @inline(__always)
  public static func overflowDataLen(_ page: UnsafeRawBufferPointer) -> Int {
    unsafe cellCount(page)
  }

  @inline(__always)
  public static func slotOffset(_ page: UnsafeRawBufferPointer, _ index: Int) -> Int {
    unsafe Int(page.loadLE16(Format.nodeHeaderSize + index * Format.slotSize))
  }

  /// Free space between the end of the slot array and cellAreaStart.
  @inline(__always)
  public static func freeSpace(_ page: UnsafeRawBufferPointer) -> Int {
    unsafe cellAreaStart(page) - (Format.nodeHeaderSize + cellCount(page) * Format.slotSize)
  }

  // MARK: Writes

  public static func initialize(_ page: UnsafeMutableRawBufferPointer, type: PageType) {
    precondition(page.count == Format.pageSize)
    unsafe page.initializeMemory(as: UInt8.self, repeating: 0)
    unsafe page[Offset.pageType] = type.rawValue
    unsafe page.storeLE16(UInt16(Format.pageSize), at: Offset.cellAreaStart)
  }

  @inline(__always)
  public static func setCellCount(_ page: UnsafeMutableRawBufferPointer, _ value: Int) {
    unsafe page.storeLE16(UInt16(value), at: Offset.cellCount)
  }
  @inline(__always)
  public static func setCellAreaStart(_ page: UnsafeMutableRawBufferPointer, _ value: Int) {
    unsafe page.storeLE16(UInt16(value), at: Offset.cellAreaStart)
  }
  @inline(__always)
  public static func setFragmentedBytes(_ page: UnsafeMutableRawBufferPointer, _ value: Int) {
    unsafe page.storeLE16(UInt16(value), at: Offset.fragmentedBytes)
  }
  @inline(__always)
  public static func setLink(_ page: UnsafeMutableRawBufferPointer, _ value: UInt64) {
    unsafe page.storeLE64(value, at: Offset.link)
  }
  @inline(__always)
  public static func setSlotOffset(_ page: UnsafeMutableRawBufferPointer, _ index: Int, _ value: Int) {
    unsafe page.storeLE16(UInt16(value), at: Format.nodeHeaderSize + index * Format.slotSize)
  }

  // MARK: Checksums

  /// Stamps the page checksum. Called exactly once per dirty page at commit.
  public static func stampChecksum(_ page: UnsafeMutableRawBufferPointer, pageNo: UInt64) {
    let body = unsafe UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(page)[8...])
    unsafe page.storeLE64(XXH64.hash(body, seed: pageNo), at: Offset.checksum)
  }

  public static func verifyChecksum(_ page: UnsafeRawBufferPointer, pageNo: UInt64) -> Bool {
    let body = unsafe UnsafeRawBufferPointer(rebasing: page[8...])
    return unsafe page.loadLE64(Offset.checksum) == XXH64.hash(body, seed: pageNo)
  }
}

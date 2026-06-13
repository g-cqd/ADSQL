import Darwin

/// Byte-level cell operations on slotted node pages. Purely mechanical —
/// COW, allocation, and tree structure live in `BTree`.
///
/// Leaf cell (inline):    [flags u8 | keyLen u16 | valueLen u16 | key | value]
/// Leaf cell (overflow):  [flags u8 | keyLen u16 | valueLen u32 | head u64 | key]
///   flags bit0 = value overflows
/// Branch cell:           [keyLen u16 | childPage u64 | key]
///
/// Slots are u16 cell offsets in key order growing up from the header; cell
/// content grows down from the page end.
public enum Node {
  public static let leafOverflowFlag: UInt8 = 0b0000_0001

  // MARK: - Key comparison (memcmp order)

  @inline(__always)
  public static func compare(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Int {
    let n = min(a.count, b.count)
    if n > 0 {
      let c = unsafe memcmp(a.baseAddress!, b.baseAddress!, n)
      if c != 0 { return c < 0 ? -1 : 1 }
    }
    if a.count == b.count { return 0 }
    return a.count < b.count ? -1 : 1
  }

  // MARK: - Sizes

  @inline(__always)
  public static func inlineLeafCellSize(keyLen: Int, valueLen: Int) -> Int { 5 + keyLen + valueLen }
  @inline(__always)
  public static func overflowLeafCellSize(keyLen: Int) -> Int { 15 + keyLen }
  @inline(__always)
  public static func branchCellSize(keyLen: Int) -> Int { 10 + keyLen }
  @inline(__always)
  public static func shouldInline(keyLen: Int, valueLen: Int) -> Bool {
    inlineLeafCellSize(keyLen: keyLen, valueLen: valueLen) <= Format.maxInlineCellSize
  }

  // MARK: - Cell decoding

  // SAFETY (Review 0001 F2): `@safe` over borrowed page pointers, asserted not
  // enforced. A LeafCell is a transient projection produced by `leafCell(page:)`
  // and consumed within the same function (read its fields, compare, copy); it
  // is never stored or returned past the page access. Making it `~Escapable`
  // would need a lifetime-bearing owner at construction, but `leafCell` takes a
  // bare `UnsafeRawBufferPointer page` (the resolver/snapshot is not in scope
  // there), so there is nothing to bind to without threading the resolver
  // through every node primitive. Owner: the page buffer of the enclosing read.
  @safe public struct LeafCell {
    public var key: UnsafeRawBufferPointer
    /// Inline payload, or nil when the value lives in an overflow chain.
    public var inlineValue: UnsafeRawBufferPointer?
    public var overflowHead: UInt64
    public var overflowLength: UInt32

    public var valueLength: Int {
      unsafe inlineValue?.count ?? Int(overflowLength)
    }
  }

  @inline(__always)
  static func cellStart(_ page: UnsafeRawBufferPointer, _ index: Int) -> Int {
    unsafe PageHeader.slotOffset(page, index)
  }

  public static func leafCell(_ page: UnsafeRawBufferPointer, _ index: Int) -> LeafCell {
    let at = unsafe cellStart(page, index)
    let flags = unsafe page[at]
    let keyLen = unsafe Int(page.loadLE16(at + 1))
    if flags & leafOverflowFlag == 0 {
      let valueLen = unsafe Int(page.loadLE16(at + 3))
      let keyStart = at + 5
      return unsafe LeafCell(
        key: UnsafeRawBufferPointer(rebasing: page[keyStart..<keyStart + keyLen]),
        inlineValue: UnsafeRawBufferPointer(
          rebasing: page[keyStart + keyLen..<keyStart + keyLen + valueLen]),
        overflowHead: 0, overflowLength: 0)
    }
    let valueLen = unsafe page.loadLE32(at + 3)
    let head = unsafe page.loadLE64(at + 7)
    let keyStart = at + 15
    return unsafe LeafCell(
      key: UnsafeRawBufferPointer(rebasing: page[keyStart..<keyStart + keyLen]),
      inlineValue: nil, overflowHead: head, overflowLength: valueLen)
  }

  @inline(__always)
  public static func branchKey(_ page: UnsafeRawBufferPointer, _ index: Int) -> UnsafeRawBufferPointer {
    let at = unsafe cellStart(page, index)
    let keyLen = unsafe Int(page.loadLE16(at))
    return unsafe UnsafeRawBufferPointer(rebasing: page[at + 10..<at + 10 + keyLen])
  }

  @inline(__always)
  public static func branchChild(_ page: UnsafeRawBufferPointer, _ index: Int) -> UInt64 {
    unsafe page.loadLE64(cellStart(page, index) + 2)
  }

  @inline(__always)
  public static func nodeKey(_ page: UnsafeRawBufferPointer, _ index: Int) -> UnsafeRawBufferPointer {
    if unsafe PageHeader.pageType(page) == .branch {
      return unsafe branchKey(page, index)
    }
    let at = unsafe cellStart(page, index)
    let flags = unsafe page[at]
    let keyLen = unsafe Int(page.loadLE16(at + 1))
    let keyStart = at + (flags & leafOverflowFlag == 0 ? 5 : 15)
    return unsafe UnsafeRawBufferPointer(rebasing: page[keyStart..<keyStart + keyLen])
  }

  /// Total encoded size of the cell at `index` (used by removal accounting
  /// and page compaction).
  public static func cellLength(_ page: UnsafeRawBufferPointer, _ index: Int) -> Int {
    let at = unsafe cellStart(page, index)
    switch unsafe PageHeader.pageType(page) {
    case .branch:
      return unsafe branchCellSize(keyLen: Int(page.loadLE16(at)))
    default:
      let flags = unsafe page[at]
      let keyLen = unsafe Int(page.loadLE16(at + 1))
      if flags & leafOverflowFlag == 0 {
        return unsafe inlineLeafCellSize(keyLen: keyLen, valueLen: Int(page.loadLE16(at + 3)))
      }
      return overflowLeafCellSize(keyLen: keyLen)
    }
  }

  // MARK: - Search

  /// Binary search over the page's cells.
  /// Returns the first index whose key is >= `key`, and whether it's exact.
  public static func search(
    _ page: UnsafeRawBufferPointer, key: UnsafeRawBufferPointer
  ) -> (index: Int, exact: Bool) {
    var lo = 0
    var hi = unsafe PageHeader.cellCount(page)
    while lo < hi {
      let mid = (lo + hi) / 2
      let c = unsafe compare(nodeKey(page, mid), key)
      if c == 0 { return (mid, true) }
      if c < 0 { lo = mid + 1 } else { hi = mid }
    }
    return (lo, false)
  }

  /// Index of the child to descend into for `key`: -1 = leftmost child.
  @inline(__always)
  public static func branchChildSlot(_ page: UnsafeRawBufferPointer, key: UnsafeRawBufferPointer) -> Int {
    let (index, exact) = unsafe search(page, key: key)
    return exact ? index : index - 1
  }

  @inline(__always)
  public static func descendTarget(_ page: UnsafeRawBufferPointer, key: UnsafeRawBufferPointer) -> UInt64 {
    let slot = unsafe branchChildSlot(page, key: key)
    return unsafe slot < 0 ? PageHeader.link(page) : branchChild(page, slot)
  }

  // MARK: - Cell encoding

  // SAFETY (Review 0001 F2): `@safe` over a borrowed pointer, asserted not
  // enforced. A LeafValue is constructed at a write site and consumed
  // synchronously by `encodeLeafCell`, which copies the inline bytes into the
  // page immediately; it is never stored. The `.inline` payload is the caller's
  // value buffer (no lifetime-bearing owner at this boundary), so binding it
  // would mean threading that owner through the encoder. Bounds: the single
  // encode call that consumes it.
  @safe public enum LeafValue {
    case inline(UnsafeRawBufferPointer)
    case overflow(head: UInt64, length: UInt32)

    var cellBodySize: Int {
      switch self {
      case .inline(let v): return 4 + v.count // valueLen u16 + value, after flags+keyLen
      case .overflow: return 14 // valueLen u32 + head u64, after flags+keyLen
      }
    }
  }

  public static func leafCellSize(keyLen: Int, value: LeafValue) -> Int {
    switch value {
    case .inline(let v): return inlineLeafCellSize(keyLen: keyLen, valueLen: v.count)
    case .overflow: return overflowLeafCellSize(keyLen: keyLen)
    }
  }

  static func encodeLeafCell(
    into page: UnsafeMutableRawBufferPointer, at offset: Int,
    key: UnsafeRawBufferPointer, value: LeafValue
  ) {
    switch value {
    case .inline(let v):
      unsafe page[offset] = 0
      unsafe page.storeLE16(UInt16(key.count), at: offset + 1)
      unsafe page.storeLE16(UInt16(v.count), at: offset + 3)
      unsafe copyBytes(into: page, at: offset + 5, from: key)
      unsafe copyBytes(into: page, at: offset + 5 + key.count, from: v)
    case .overflow(let head, let length):
      unsafe page[offset] = leafOverflowFlag
      unsafe page.storeLE16(UInt16(key.count), at: offset + 1)
      unsafe page.storeLE32(length, at: offset + 3)
      unsafe page.storeLE64(head, at: offset + 7)
      unsafe copyBytes(into: page, at: offset + 15, from: key)
    }
  }

  static func encodeBranchCell(
    into page: UnsafeMutableRawBufferPointer, at offset: Int,
    key: UnsafeRawBufferPointer, child: UInt64
  ) {
    unsafe page.storeLE16(UInt16(key.count), at: offset)
    unsafe page.storeLE64(child, at: offset + 2)
    unsafe copyBytes(into: page, at: offset + 10, from: key)
  }

  @inline(__always)
  static func copyBytes(
    into page: UnsafeMutableRawBufferPointer, at offset: Int, from source: UnsafeRawBufferPointer
  ) {
    guard unsafe !source.isEmpty else { return }
    unsafe UnsafeMutableRawBufferPointer(rebasing: page[offset..<offset + source.count])
      .copyMemory(from: source)
  }

  // MARK: - Insertion / removal

  /// Inserts an encoded cell of `size` bytes at slot `index`, claiming space
  /// from the cell area. Returns false when the page cannot fit it (split).
  static func insertCell(
    _ page: UnsafeMutableRawBufferPointer, at index: Int, size: Int,
    write: (UnsafeMutableRawBufferPointer, Int) -> Void
  ) -> Bool {
    let ro = UnsafeRawBufferPointer(page)
    let need = size + Format.slotSize
    if unsafe PageHeader.freeSpace(ro) < need {
      if unsafe PageHeader.freeSpace(ro) + PageHeader.fragmentedBytes(ro) >= need {
        unsafe compact(page)
      } else {
        return false
      }
    }
    let count = unsafe PageHeader.cellCount(ro)
    let newOffset = unsafe PageHeader.cellAreaStart(ro) - size
    unsafe write(page, newOffset)

    // Shift slots [index, count) up one position.
    let slotBase = Format.nodeHeaderSize
    if count > index {
      let src = slotBase + index * Format.slotSize
      let len = (count - index) * Format.slotSize
      unsafe memmove(page.baseAddress! + src + Format.slotSize, page.baseAddress! + src, len)
    }
    unsafe PageHeader.setSlotOffset(page, index, newOffset)
    unsafe PageHeader.setCellCount(page, count + 1)
    unsafe PageHeader.setCellAreaStart(page, newOffset)
    return true
  }

  public static func leafInsert(
    _ page: UnsafeMutableRawBufferPointer, at index: Int,
    key: UnsafeRawBufferPointer, value: LeafValue
  ) -> Bool {
    unsafe insertCell(page, at: index, size: leafCellSize(keyLen: key.count, value: value)) {
      unsafe encodeLeafCell(into: $0, at: $1, key: key, value: value)
    }
  }

  public static func branchInsert(
    _ page: UnsafeMutableRawBufferPointer, at index: Int,
    key: UnsafeRawBufferPointer, child: UInt64
  ) -> Bool {
    unsafe insertCell(page, at: index, size: branchCellSize(keyLen: key.count)) {
      unsafe encodeBranchCell(into: $0, at: $1, key: key, child: child)
    }
  }

  /// Removes the cell at slot `index`, accounting its bytes as fragmented
  /// (or reclaiming directly when it borders the cell area start).
  public static func removeCell(_ page: UnsafeMutableRawBufferPointer, at index: Int) {
    let ro = UnsafeRawBufferPointer(page)
    let count = unsafe PageHeader.cellCount(ro)
    let offset = unsafe PageHeader.slotOffset(ro, index)
    let length = unsafe cellLength(ro, index)

    let slotBase = Format.nodeHeaderSize
    if index < count - 1 {
      let dst = slotBase + index * Format.slotSize
      let len = (count - 1 - index) * Format.slotSize
      unsafe memmove(page.baseAddress! + dst, page.baseAddress! + dst + Format.slotSize, len)
    }
    unsafe PageHeader.setCellCount(page, count - 1)
    if unsafe offset == PageHeader.cellAreaStart(ro) {
      unsafe PageHeader.setCellAreaStart(page, offset + length)
    } else {
      unsafe PageHeader.setFragmentedBytes(page, PageHeader.fragmentedBytes(ro) + length)
    }
  }

  /// Overwrites the child pointer of a branch cell in place (fixed width).
  public static func branchSetChild(
    _ page: UnsafeMutableRawBufferPointer, at index: Int, child: UInt64
  ) {
    let offset = unsafe PageHeader.slotOffset(UnsafeRawBufferPointer(page), index)
    unsafe page.storeLE64(child, at: offset + 2)
  }

  // MARK: - Compaction

  /// Rewrites the cell area densely (slot order preserved), clearing
  /// fragmentation. Uses a scratch copy of the page.
  public static func compact(_ page: UnsafeMutableRawBufferPointer) {
    let scratch = unsafe PageBuf(copying: UnsafeRawBufferPointer(page))
    let ro = unsafe scratch.readOnly
    let count = unsafe PageHeader.cellCount(ro)
    var writeEnd = Format.pageSize
    for i in 0..<count {
      let length = unsafe cellLength(ro, i)
      let src = unsafe PageHeader.slotOffset(ro, i)
      writeEnd -= length
      unsafe copyBytes(
        into: page, at: writeEnd,
        from: UnsafeRawBufferPointer(rebasing: ro[src..<src + length]))
      unsafe PageHeader.setSlotOffset(page, i, writeEnd)
    }
    unsafe PageHeader.setCellAreaStart(page, writeEnd)
    unsafe PageHeader.setFragmentedBytes(page, 0)
  }

  // MARK: - Splits

  /// Copied image of every cell on a page, in slot order.
  static func cellImages(_ page: UnsafeRawBufferPointer) -> [[UInt8]] {
    let count = unsafe PageHeader.cellCount(page)
    var cells: [[UInt8]] = []
    cells.reserveCapacity(count + 1)
    for i in 0..<count {
      let offset = unsafe PageHeader.slotOffset(page, i)
      unsafe cells.append([UInt8](page[offset..<offset + cellLength(page, i)]))
    }
    return cells
  }

  static func keyOfCellImage(_ cell: [UInt8], type: PageType) -> [UInt8] {
    cell.withUnsafeBytes { raw in
      switch type {
      case .branch:
        let keyLen = unsafe Int(raw.loadLE16(0))
        return [UInt8](cell[10..<10 + keyLen])
      default:
        let keyLen = unsafe Int(raw.loadLE16(1))
        let keyStart = unsafe raw[0] & leafOverflowFlag == 0 ? 5 : 15
        return [UInt8](cell[keyStart..<keyStart + keyLen])
      }
    }
  }

  static func rebuild(
    _ page: UnsafeMutableRawBufferPointer, type: PageType, cells: ArraySlice<[UInt8]>,
    leftmostChild: UInt64
  ) {
    unsafe PageHeader.initialize(page, type: type)
    unsafe PageHeader.setLink(page, leftmostChild)
    var writeEnd = Format.pageSize
    var slot = 0
    for cell in cells {
      writeEnd -= cell.count
      cell.withUnsafeBytes { unsafe copyBytes(into: page, at: writeEnd, from: $0) }
      unsafe PageHeader.setSlotOffset(page, slot, writeEnd)
      slot += 1
    }
    unsafe PageHeader.setCellCount(page, slot)
    unsafe PageHeader.setCellAreaStart(page, writeEnd)
  }

  /// Picks the split point: smallest prefix carrying at least half the bytes,
  /// clamped so both sides are non-empty.
  static func splitPoint(_ cells: [[UInt8]]) -> Int {
    let total = cells.reduce(0) { $0 + $1.count + Format.slotSize }
    var acc = 0
    for (i, cell) in cells.enumerated() {
      acc += cell.count + Format.slotSize
      if acc * 2 >= total {
        return min(max(i + 1, 1), cells.count - 1)
      }
    }
    return cells.count - 1
  }

  /// Splits a full leaf while inserting (key, value) at `index`.
  /// `left` may alias the original page's buffer. Returns the separator key
  /// (first key of the right page).
  public static func splitLeafInserting(
    original: UnsafeRawBufferPointer, at index: Int,
    key: UnsafeRawBufferPointer, value: LeafValue,
    left: UnsafeMutableRawBufferPointer, right: UnsafeMutableRawBufferPointer
  ) -> [UInt8] {
    var cells = unsafe cellImages(original)
    var newCell = [UInt8](repeating: 0, count: leafCellSize(keyLen: key.count, value: value))
    newCell.withUnsafeMutableBytes { raw in
      unsafe encodeLeafCell(
        into: UnsafeMutableRawBufferPointer(mutating: UnsafeRawBufferPointer(raw)), at: 0,
        key: key, value: value)
    }
    cells.insert(newCell, at: index)
    // Append/prepend bias: a key inserted at a leaf edge is the signature of a
    // sequential (often bulk) load. A 50/50 split there strands the just-filled
    // side at ~50% forever; keeping it packed and starting the new side with the
    // single edge cell yields ~100% fill on monotonic loads (random inserts land
    // interior and fall back to the balanced split).
    let split: Int
    if index == cells.count - 1 {
      split = cells.count - 1
    } else if index == 0 {
      split = 1
    } else {
      split = splitPoint(cells)
    }
    unsafe rebuild(left, type: .leaf, cells: cells[..<split], leftmostChild: 0)
    unsafe rebuild(right, type: .leaf, cells: cells[split...], leftmostChild: 0)
    return keyOfCellImage(cells[split], type: .leaf)
  }

  /// Splits a full branch while inserting (key, child) at cell position
  /// `index`. The middle key moves *up*: it is returned as the separator and
  /// its child becomes the right page's leftmost child.
  public static func splitBranchInserting(
    original: UnsafeRawBufferPointer, at index: Int,
    key: UnsafeRawBufferPointer, child: UInt64,
    left: UnsafeMutableRawBufferPointer, right: UnsafeMutableRawBufferPointer
  ) -> [UInt8] {
    let leftmost = unsafe PageHeader.link(original)
    var cells = unsafe cellImages(original)
    var newCell = [UInt8](repeating: 0, count: branchCellSize(keyLen: key.count))
    newCell.withUnsafeMutableBytes { raw in
      unsafe encodeBranchCell(
        into: UnsafeMutableRawBufferPointer(mutating: UnsafeRawBufferPointer(raw)), at: 0,
        key: key, child: child)
    }
    cells.insert(newCell, at: index)
    let mid = splitPoint(cells)
    let separator = keyOfCellImage(cells[mid], type: .branch)
    let promotedChild = cells[mid].withUnsafeBytes { unsafe $0.loadLE64(2) }
    unsafe rebuild(left, type: .branch, cells: cells[..<mid], leftmostChild: leftmost)
    unsafe rebuild(right, type: .branch, cells: cells[(mid + 1)...], leftmostChild: promotedChild)
    return separator
  }
}

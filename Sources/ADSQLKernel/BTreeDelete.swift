/// Deletion with merge-or-borrow rebalancing.
///
/// A node falling under quarter-page payload (or emptied) merges with a
/// sibling when the combined payload fits one page, otherwise borrows the
/// sibling's edge cell (rotating it through the parent separator). Only pages
/// that actually mutate are shadowed; a page that merely disappears in a
/// merge is read in place and freed.
extension BTree {
  struct PathNode {
    var pageNo: UInt64
    var buf: PageBuf
    /// Child position taken during descent: -1 = leftmost link.
    var slot: Int
  }

  /// Returns true when the key existed.
  public static func delete(
    ctx: TxnContext, key: UnsafeRawBufferPointer
  ) throws(DBError) -> Bool {
    guard !key.isEmpty else { throw DBError.keyEmpty }
    guard key.count <= Format.maxKeySize else { throw DBError.keyTooLarge(key.count) }
    guard ctx.meta.rootPage != 0 else { return false }

    // Existence probe first: missing keys must not shadow anything.
    guard try get(resolver: ctx, meta: ctx.meta, key: key) != nil else { return false }

    var (currentNo, currentBuf) = try ctx.shadow(ctx.meta.rootPage)
    ctx.meta.rootPage = currentNo
    var path: [PathNode] = []

    var level = ctx.meta.treeDepth
    while level > 1 {
      let ro = currentBuf.readOnly
      let slot = Node.branchChildSlot(ro, key: key)
      let childNo = slot < 0 ? PageHeader.link(ro) : Node.branchChild(ro, slot)
      let (newChildNo, childBuf) = try ctx.shadow(childNo)
      if newChildNo != childNo {
        if slot < 0 {
          PageHeader.setLink(currentBuf.raw, newChildNo)
        } else {
          Node.branchSetChild(currentBuf.raw, at: slot, child: newChildNo)
        }
      }
      path.append(PathNode(pageNo: currentNo, buf: currentBuf, slot: slot))
      (currentNo, currentBuf) = (newChildNo, childBuf)
      level -= 1
    }

    let ro = currentBuf.readOnly
    let (index, exact) = Node.search(ro, key: key)
    guard exact else {
      throw DBError.integrityFailure("delete probe found key but descent did not")
    }
    let cell = Node.leafCell(ro, index)
    if cell.inlineValue == nil {
      var pager = ctx
      try Overflow.free(head: cell.overflowHead, pager: &pager)
    }
    Node.removeCell(currentBuf.raw, at: index)
    ctx.meta.kvCount -= 1

    try rebalance(ctx, path: path, nodePageNo: currentNo, nodeBuf: currentBuf, level: path.count)
    return true
  }

  // MARK: - Rebalancing

  @inline(__always)
  static func payloadBytes(_ page: UnsafeRawBufferPointer) -> Int {
    (Format.pageSize - PageHeader.cellAreaStart(page) - PageHeader.fragmentedBytes(page))
      + PageHeader.cellCount(page) * Format.slotSize
  }

  static var rebalanceThreshold: Int { Format.usablePageSize / 4 }

  /// `level == path.count` means `node` is the leaf; otherwise
  /// `path[level]` *is* the node.
  private static func rebalance(
    _ ctx: TxnContext, path: [PathNode],
    nodePageNo: UInt64, nodeBuf: PageBuf, level: Int
  ) throws(DBError) {
    let ro = nodeBuf.readOnly
    let isLeaf = level == path.count

    if level == 0 || (path.isEmpty && isLeaf) {
      // Root rules: empty the tree, or collapse one height level.
      if isLeaf {
        if PageHeader.cellCount(ro) == 0 {
          ctx.freePage(nodePageNo)
          ctx.meta.rootPage = 0
          ctx.meta.treeDepth = 0
        }
      } else if PageHeader.cellCount(ro) == 0 {
        ctx.meta.rootPage = PageHeader.link(ro)
        ctx.meta.treeDepth -= 1
        ctx.freePage(nodePageNo)
      }
      return
    }

    if payloadBytes(ro) >= rebalanceThreshold {
      return
    }

    let parent = path[level - 1]
    let parentRO = parent.buf.readOnly
    let parentCount = PageHeader.cellCount(parentRO)
    let slot = parent.slot

    if slot + 1 <= parentCount - 1 {
      // Right sibling exists: (left=node, right=sibling), parent cell slot+1.
      let rightNo = Node.branchChild(parentRO, slot + 1)
      try rebalancePair(
        ctx, path: path, level: level,
        leftNo: nodePageNo, leftBuf: nodeBuf, leftIsTarget: true,
        rightNo: rightNo, rightBuf: nil,
        parentCellIndex: slot + 1, isLeaf: isLeaf)
    } else if slot >= 0 {
      // Only a left sibling: (left=sibling, right=node), parent cell `slot`.
      let leftNo = slot == 0 ? PageHeader.link(parentRO) : Node.branchChild(parentRO, slot - 1)
      try rebalancePair(
        ctx, path: path, level: level,
        leftNo: leftNo, leftBuf: nil, leftIsTarget: false,
        rightNo: nodePageNo, rightBuf: nodeBuf,
        parentCellIndex: slot, isLeaf: isLeaf)
    }
    // slot == -1 with no cell at 0 cannot occur: branches keep ≥ 1 cell.
  }

  /// Merges or borrows between an adjacent (left, right) pair under the
  /// parent cell `parentCellIndex` (the cell pointing at `right`). The target
  /// (underfull) side is `leftIsTarget ? left : right`; its buffer is already
  /// transaction-owned. The sibling's buffer is nil until shadowed on demand.
  private static func rebalancePair(
    _ ctx: TxnContext, path: [PathNode], level: Int,
    leftNo: UInt64, leftBuf: PageBuf?, leftIsTarget: Bool,
    rightNo: UInt64, rightBuf: PageBuf?,
    parentCellIndex: Int, isLeaf: Bool
  ) throws(DBError) {
    let parent = path[level - 1]
    let separator = [UInt8](Node.branchKey(parent.buf.readOnly, parentCellIndex))

    let leftRO: UnsafeRawBufferPointer =
      if let leftBuf { leftBuf.readOnly } else { try ctx.resolvePage(leftNo) }
    let rightRO: UnsafeRawBufferPointer =
      if let rightBuf { rightBuf.readOnly } else { try ctx.resolvePage(rightNo) }

    let mergedPayload =
      payloadBytes(leftRO) + payloadBytes(rightRO)
      + (isLeaf ? 0 : Node.branchCellSize(keyLen: separator.count) + Format.slotSize)

    if mergedPayload <= Format.usablePageSize {
      // MERGE right into left: left mutates, right dies unshadowed.
      let (newLeftNo, leftOwned) = try ctx.shadow(leftNo)
      if newLeftNo != leftNo {
        repointChild(parent.buf, cellIndex: parentCellIndex - 1, to: newLeftNo)
      }
      if !isLeaf {
        let ok = separator.withUnsafeBytes { sep in
          Node.branchInsert(
            leftOwned.raw, at: PageHeader.cellCount(leftOwned.readOnly),
            key: sep, child: PageHeader.link(rightRO))
        }
        precondition(ok, "merge size was pre-checked")
      }
      appendAllCells(from: rightRO, to: leftOwned)
      ctx.freePage(rightNo)
      Node.removeCell(parent.buf.raw, at: parentCellIndex)
      try rebalance(
        ctx, path: path,
        nodePageNo: parent.pageNo, nodeBuf: parent.buf, level: level - 1)
      return
    }

    // BORROW the richer side's edge cell into the target.
    let (newLeftNo, leftOwned) = try ctx.shadow(leftNo)
    if newLeftNo != leftNo {
      repointChild(parent.buf, cellIndex: parentCellIndex - 1, to: newLeftNo)
    }
    let (newRightNo, rightOwned) = try ctx.shadow(rightNo)
    if newRightNo != rightNo {
      repointChild(parent.buf, cellIndex: parentCellIndex, to: newRightNo)
    }

    let newSeparator: [UInt8]
    if leftIsTarget {
      // Move right's first cell into left.
      let rRO = rightOwned.readOnly
      if isLeaf {
        let image = cellImage(rRO, 0)
        Node.removeCell(rightOwned.raw, at: 0)
        appendCellImage(image, to: leftOwned)
        newSeparator = [UInt8](Node.nodeKey(rightOwned.readOnly, 0))
      } else {
        let ok = separator.withUnsafeBytes { sep in
          Node.branchInsert(
            leftOwned.raw, at: PageHeader.cellCount(leftOwned.readOnly),
            key: sep, child: PageHeader.link(rRO))
        }
        precondition(ok, "borrow target was underfull")
        newSeparator = [UInt8](Node.branchKey(rRO, 0))
        PageHeader.setLink(rightOwned.raw, Node.branchChild(rRO, 0))
        Node.removeCell(rightOwned.raw, at: 0)
      }
    } else {
      // Move left's last cell into right.
      let lRO = leftOwned.readOnly
      let lastIndex = PageHeader.cellCount(lRO) - 1
      if isLeaf {
        let image = cellImage(lRO, lastIndex)
        newSeparator = Node.keyOfCellImage(image, type: .leaf)
        Node.removeCell(leftOwned.raw, at: lastIndex)
        let ok = image.withUnsafeBytes { raw in
          insertCellImage(raw, into: rightOwned, at: 0)
        }
        precondition(ok, "borrow target was underfull")
      } else {
        newSeparator = [UInt8](Node.branchKey(lRO, lastIndex))
        let pushedChild = Node.branchChild(lRO, lastIndex)
        let oldLeftmost = PageHeader.link(rightOwned.readOnly)
        let ok = separator.withUnsafeBytes { sep in
          Node.branchInsert(rightOwned.raw, at: 0, key: sep, child: oldLeftmost)
        }
        precondition(ok, "borrow target was underfull")
        PageHeader.setLink(rightOwned.raw, pushedChild)
        Node.removeCell(leftOwned.raw, at: lastIndex)
      }
    }

    replaceSeparator(
      ctx, path: path, parentLevel: level - 1,
      cellIndex: parentCellIndex, newKey: newSeparator)
  }

  /// Rewrites the parent cell `cellIndex` to carry `newKey` (child
  /// preserved). Variable-length keys can overflow the parent — then it
  /// splits like any other branch insert.
  private static func replaceSeparator(
    _ ctx: TxnContext, path: [PathNode], parentLevel: Int,
    cellIndex: Int, newKey: [UInt8]
  ) {
    let parent = path[parentLevel]
    let child = Node.branchChild(parent.buf.readOnly, cellIndex)
    Node.removeCell(parent.buf.raw, at: cellIndex)
    let inserted = newKey.withUnsafeBytes { sep in
      Node.branchInsert(parent.buf.raw, at: cellIndex, key: sep, child: child)
    }
    if inserted { return }
    let (newRightNo, newRightBuf) = ctx.allocatePage()
    let upSeparator = newKey.withUnsafeBytes { sep in
      Node.splitBranchInserting(
        original: parent.buf.readOnly, at: cellIndex, key: sep, child: child,
        left: parent.buf.raw, right: newRightBuf.raw)
    }
    insertSeparator(
      ctx, path: path[..<parentLevel].map { (buf: $0.buf, slot: $0.slot) },
      separator: upSeparator, rightChild: newRightNo)
  }

  // MARK: - Small helpers

  /// Repoints the parent's child reference `cellIndex` (-1 = leftmost link).
  private static func repointChild(
    _ parentBuf: PageBuf, cellIndex: Int, to newChild: UInt64
  ) {
    if cellIndex < 0 {
      PageHeader.setLink(parentBuf.raw, newChild)
    } else {
      Node.branchSetChild(parentBuf.raw, at: cellIndex, child: newChild)
    }
  }

  static func cellImage(_ page: UnsafeRawBufferPointer, _ index: Int) -> [UInt8] {
    let offset = PageHeader.slotOffset(page, index)
    return [UInt8](page[offset..<offset + Node.cellLength(page, index)])
  }

  private static func appendCellImage(_ image: [UInt8], to buf: PageBuf) {
    let ok = image.withUnsafeBytes { raw in
      insertCellImage(raw, into: buf, at: PageHeader.cellCount(buf.readOnly))
    }
    precondition(ok, "append target was pre-checked")
  }

  private static func insertCellImage(
    _ image: UnsafeRawBufferPointer, into buf: PageBuf, at index: Int
  ) -> Bool {
    Node.insertCell(buf.raw, at: index, size: image.count) { page, offset in
      Node.copyBytes(into: page, at: offset, from: image)
    }
  }

  private static func appendAllCells(from source: UnsafeRawBufferPointer, to buf: PageBuf) {
    for i in 0..<PageHeader.cellCount(source) {
      let offset = PageHeader.slotOffset(source, i)
      let length = Node.cellLength(source, i)
      let ok = Node.insertCell(
        buf.raw, at: PageHeader.cellCount(buf.readOnly), size: length
      ) { page, dst in
        Node.copyBytes(
          into: page, at: dst,
          from: UnsafeRawBufferPointer(rebasing: source[offset..<offset + length]))
      }
      precondition(ok, "merge size was pre-checked")
    }
  }
}

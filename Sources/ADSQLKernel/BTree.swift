/// The copy-on-write B+tree. Writes shadow every page on the descent path
/// (COW-once-per-transaction: a page already owned by the transaction is
/// mutated in place), so committed pages are never touched and readers on
/// older generations stay consistent without locks.
public enum BTree {
  public enum ValueRef {
    case inline(UnsafeRawBufferPointer)
    case overflow(head: UInt64, length: Int)

    public var length: Int {
      switch self {
      case .inline(let v): return v.count
      case .overflow(_, let length): return length
      }
    }
  }

  // MARK: - Lookup

  @inline(__always)
  public static func get(
    resolver: some PageResolver, meta: Meta, key: UnsafeRawBufferPointer
  ) throws(DBError) -> ValueRef? {
    try get(resolver: resolver, tree: meta.mainTree, key: key)
  }

  public static func get(
    resolver: some PageResolver, tree: TreeHandle, key: UnsafeRawBufferPointer
  ) throws(DBError) -> ValueRef? {
    guard tree.rootPage != 0 else { return nil }
    var pageNo = tree.rootPage
    var level = tree.depth
    while level > 1 {
      let page = try resolver.resolvePage(pageNo)
      guard PageHeader.pageType(page) == .branch else {
        throw DBError.corruptPage(pageNo: pageNo)
      }
      pageNo = Node.descendTarget(page, key: key)
      level -= 1
    }
    let leaf = try resolver.resolvePage(pageNo)
    guard PageHeader.pageType(leaf) == .leaf else {
      throw DBError.corruptPage(pageNo: pageNo)
    }
    let (index, exact) = Node.search(leaf, key: key)
    guard exact else { return nil }
    let cell = Node.leafCell(leaf, index)
    if let inline = cell.inlineValue { return .inline(inline) }
    return .overflow(head: cell.overflowHead, length: Int(cell.overflowLength))
  }

  /// Materializes a value reference (copying inline bytes or concatenating
  /// the overflow chain).
  public static func copyValue(
    _ ref: ValueRef, resolver: some PageResolver
  ) throws(DBError) -> [UInt8] {
    switch ref {
    case .inline(let bytes):
      return [UInt8](bytes)
    case .overflow(let head, let length):
      return try Overflow.read(
        head: head, length: length, pager: ReadOnlyOverflowPager(resolver: resolver))
    }
  }

  // MARK: - Insert / update

  @inline(__always)
  public static func put(
    ctx: TxnContext, key: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer
  ) throws(DBError) {
    var tree = ctx.meta.mainTree
    try put(ctx: ctx, tree: &tree, key: key, value: value)
    ctx.meta.mainTree = tree
  }

  public static func put(
    ctx: TxnContext, tree: inout TreeHandle,
    key: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer
  ) throws(DBError) {
    guard !key.isEmpty else { throw DBError.keyEmpty }
    guard key.count <= Format.maxKeySize else { throw DBError.keyTooLarge(key.count) }

    var pager = ctx
    let leafValue: Node.LeafValue
    if Node.shouldInline(keyLen: key.count, valueLen: value.count) {
      leafValue = .inline(value)
    } else {
      let head = try Overflow.write(value, pager: &pager)
      leafValue = .overflow(head: head, length: UInt32(value.count))
    }

    // Empty tree: the new leaf is the root.
    if tree.rootPage == 0 {
      let (rootNo, buf) = ctx.allocatePage()
      PageHeader.initialize(buf.raw, type: .leaf)
      _ = Node.leafInsert(buf.raw, at: 0, key: key, value: leafValue)
      tree.rootPage = rootNo
      tree.depth = 1
      tree.count += 1
      return
    }

    // Shadow the descent path top-down, repointing parents as pages move.
    var (currentNo, currentBuf) = try ctx.shadow(tree.rootPage)
    tree.rootPage = currentNo
    var path: [(buf: PageBuf, slot: Int)] = []
    path.reserveCapacity(Int(tree.depth))

    var level = tree.depth
    while level > 1 {
      let ro = currentBuf.readOnly
      guard PageHeader.pageType(ro) == .branch else {
        throw DBError.corruptPage(pageNo: currentNo)
      }
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
      path.append((currentBuf, slot))
      (currentNo, currentBuf) = (newChildNo, childBuf)
      level -= 1
    }

    let ro = currentBuf.readOnly
    guard PageHeader.pageType(ro) == .leaf else {
      throw DBError.corruptPage(pageNo: currentNo)
    }
    let (index, exact) = Node.search(ro, key: key)
    if exact {
      // Replace: drop the old cell (and its overflow chain) first.
      let old = Node.leafCell(ro, index)
      if old.inlineValue == nil {
        try Overflow.free(head: old.overflowHead, pager: &pager)
      }
      Node.removeCell(currentBuf.raw, at: index)
    } else {
      tree.count += 1
    }

    if Node.leafInsert(currentBuf.raw, at: index, key: key, value: leafValue) {
      return
    }

    // Leaf overflowed: split (left half stays on the shadowed page).
    let (rightNo, rightBuf) = ctx.allocatePage()
    let separator = Node.splitLeafInserting(
      original: currentBuf.readOnly, at: index, key: key, value: leafValue,
      left: currentBuf.raw, right: rightBuf.raw)
    insertSeparator(ctx, tree: &tree, path: path, separator: separator, rightChild: rightNo)
  }

  /// Propagates a split upward. `path` holds the shadowed branch chain from
  /// the root (exclusive of the split node); all buffers are transaction-owned.
  static func insertSeparator(
    _ ctx: TxnContext, tree: inout TreeHandle, path: [(buf: PageBuf, slot: Int)],
    separator: [UInt8], rightChild: UInt64
  ) {
    var separator = separator
    var rightChild = rightChild
    var level = path.count - 1

    while level >= 0 {
      let parent = path[level]
      let insertAt = parent.slot + 1
      let inserted = separator.withUnsafeBytes { sep in
        Node.branchInsert(parent.buf.raw, at: insertAt, key: sep, child: rightChild)
      }
      if inserted { return }

      let (newRightNo, newRightBuf) = ctx.allocatePage()
      let upSeparator = separator.withUnsafeBytes { sep in
        Node.splitBranchInserting(
          original: parent.buf.readOnly, at: insertAt, key: sep, child: rightChild,
          left: parent.buf.raw, right: newRightBuf.raw)
      }
      separator = upSeparator
      rightChild = newRightNo
      level -= 1
    }

    // Root split: grow the tree by one level.
    let (newRootNo, rootBuf) = ctx.allocatePage()
    PageHeader.initialize(rootBuf.raw, type: .branch)
    PageHeader.setLink(rootBuf.raw, tree.rootPage)
    let ok = separator.withUnsafeBytes { sep in
      Node.branchInsert(rootBuf.raw, at: 0, key: sep, child: rightChild)
    }
    precondition(ok, "fresh root must fit one separator")
    tree.rootPage = newRootNo
    tree.depth += 1
  }

  // MARK: - Traversal (tests, integrity, future cursors build on this)

  /// In-order traversal of every (key, valueRef) pair.
  @inline(__always)
  public static func forEach(
    resolver: some PageResolver, meta: Meta,
    _ body: (UnsafeRawBufferPointer, ValueRef) throws(DBError) -> Void
  ) throws(DBError) {
    try forEach(resolver: resolver, tree: meta.mainTree, body)
  }

  public static func forEach(
    resolver: some PageResolver, tree: TreeHandle,
    _ body: (UnsafeRawBufferPointer, ValueRef) throws(DBError) -> Void
  ) throws(DBError) {
    guard tree.rootPage != 0 else { return }
    try walk(resolver: resolver, pageNo: tree.rootPage, level: tree.depth, body)
  }

  private static func walk(
    resolver: some PageResolver, pageNo: UInt64, level: UInt16,
    _ body: (UnsafeRawBufferPointer, ValueRef) throws(DBError) -> Void
  ) throws(DBError) {
    let page = try resolver.resolvePage(pageNo)
    if level > 1 {
      guard PageHeader.pageType(page) == .branch else {
        throw DBError.corruptPage(pageNo: pageNo)
      }
      try walk(resolver: resolver, pageNo: PageHeader.link(page), level: level - 1, body)
      for i in 0..<PageHeader.cellCount(page) {
        try walk(resolver: resolver, pageNo: Node.branchChild(page, i), level: level - 1, body)
      }
      return
    }
    guard PageHeader.pageType(page) == .leaf else {
      throw DBError.corruptPage(pageNo: pageNo)
    }
    for i in 0..<PageHeader.cellCount(page) {
      let cell = Node.leafCell(page, i)
      if let inline = cell.inlineValue {
        try body(cell.key, .inline(inline))
      } else {
        try body(cell.key, .overflow(head: cell.overflowHead, length: Int(cell.overflowLength)))
      }
    }
  }

  // MARK: - Structural validation

  public struct ValidationReport: Sendable {
    public var reachablePages: Set<UInt64> = []
    public var kvCount: UInt64 = 0
    public var leafCount = 0
    public var branchCount = 0
    public var overflowPages = 0
  }

  /// Full structural check of the tree under `meta`: page types, in-node key
  /// order, separator bounds, uniform leaf depth, overflow chain lengths.
  /// Returns the set of reachable pages for liveness accounting.
  @inline(__always)
  public static func validate(
    resolver: some PageResolver, meta: Meta, verifyChecksums: Bool = false
  ) throws(DBError) -> ValidationReport {
    try validate(resolver: resolver, tree: meta.mainTree, verifyChecksums: verifyChecksums)
  }

  public static func validate(
    resolver: some PageResolver, tree: TreeHandle, verifyChecksums: Bool = false
  ) throws(DBError) -> ValidationReport {
    var report = ValidationReport()
    if tree.rootPage != 0 {
      try validateNode(
        resolver: resolver, pageNo: tree.rootPage, level: tree.depth,
        lower: nil, upper: nil, isRoot: true, verifyChecksums: verifyChecksums,
        report: &report)
    }
    guard report.kvCount == tree.count else {
      throw DBError.integrityFailure(
        "count mismatch: tree has \(report.kvCount), handle says \(tree.count)")
    }
    return report
  }

  private static func validateNode(
    resolver: some PageResolver, pageNo: UInt64, level: UInt16,
    lower: [UInt8]?, upper: [UInt8]?, isRoot: Bool = false,
    verifyChecksums: Bool = false,
    report: inout ValidationReport
  ) throws(DBError) {
    guard report.reachablePages.insert(pageNo).inserted else {
      throw DBError.integrityFailure("page \(pageNo) reachable twice")
    }
    let page = try resolver.resolvePage(pageNo)
    if verifyChecksums, !PageHeader.verifyChecksum(page, pageNo: pageNo) {
      throw DBError.corruptPage(pageNo: pageNo)
    }
    let count = PageHeader.cellCount(page)

    func checkOrderAndBounds() throws(DBError) {
      for i in 0..<count {
        let key = Node.nodeKey(page, i)
        if i > 0, Node.compare(Node.nodeKey(page, i - 1), key) >= 0 {
          throw DBError.integrityFailure("page \(pageNo): keys out of order at \(i)")
        }
        let lowerOK = lower.map { l in l.withUnsafeBytes { Node.compare($0, key) <= 0 } } ?? true
        let upperOK = upper.map { u in u.withUnsafeBytes { Node.compare(key, $0) < 0 } } ?? true
        guard lowerOK, upperOK else {
          throw DBError.integrityFailure("page \(pageNo): key \(i) outside separator bounds")
        }
      }
    }

    if level > 1 {
      guard PageHeader.pageType(page) == .branch else {
        throw DBError.corruptPage(pageNo: pageNo)
      }
      guard count >= 1 else {
        throw DBError.integrityFailure("branch \(pageNo) has no separators")
      }
      report.branchCount += 1
      try checkOrderAndBounds()
      // leftmost child: (lower, key[0])
      try validateNode(
        resolver: resolver, pageNo: PageHeader.link(page), level: level - 1,
        lower: lower, upper: [UInt8](Node.branchKey(page, 0)),
        verifyChecksums: verifyChecksums, report: &report)
      for i in 0..<count {
        let childLower = [UInt8](Node.branchKey(page, i))
        let childUpper = i + 1 < count ? [UInt8](Node.branchKey(page, i + 1)) : upper
        try validateNode(
          resolver: resolver, pageNo: Node.branchChild(page, i), level: level - 1,
          lower: childLower, upper: childUpper,
          verifyChecksums: verifyChecksums, report: &report)
      }
      return
    }

    guard PageHeader.pageType(page) == .leaf else {
      throw DBError.corruptPage(pageNo: pageNo)
    }
    guard isRoot || count >= 1 else {
      throw DBError.integrityFailure("empty non-root leaf \(pageNo)")
    }
    report.leafCount += 1
    try checkOrderAndBounds()
    report.kvCount += UInt64(count)
    for i in 0..<count {
      let cell = Node.leafCell(page, i)
      if cell.inlineValue == nil {
        var chainPage = cell.overflowHead
        var remaining = Int(cell.overflowLength)
        while chainPage != 0 {
          guard report.reachablePages.insert(chainPage).inserted else {
            throw DBError.integrityFailure("overflow page \(chainPage) reachable twice")
          }
          report.overflowPages += 1
          let overflow = try resolver.resolvePage(chainPage)
          if verifyChecksums, !PageHeader.verifyChecksum(overflow, pageNo: chainPage) {
            throw DBError.corruptPage(pageNo: chainPage)
          }
          guard PageHeader.pageType(overflow) == .overflow else {
            throw DBError.corruptPage(pageNo: chainPage)
          }
          remaining -= PageHeader.overflowDataLen(overflow)
          chainPage = PageHeader.link(overflow)
        }
        guard remaining == 0 else {
          throw DBError.integrityFailure(
            "overflow chain \(cell.overflowHead): length mismatch (\(remaining) left)")
        }
      }
    }
  }
}

/// Read-only adapter so lookups can stream overflow chains through any
/// resolver. Mutating members trap: reads never allocate or free.
struct ReadOnlyOverflowPager<R: PageResolver>: OverflowPager {
  let resolver: R

  func allocateOverflowPage() throws(DBError) -> (pageNo: UInt64, buffer: UnsafeMutableRawBufferPointer) {
    preconditionFailure("read-only pager cannot allocate")
  }
  func readOverflowPage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
    try resolver.resolvePage(pageNo)
  }
  func freeOverflowPage(_ pageNo: UInt64) throws(DBError) {
    preconditionFailure("read-only pager cannot free")
  }
}

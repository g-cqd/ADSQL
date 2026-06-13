/// Ordered iteration over one tree snapshot. The cursor keeps a root-to-leaf
/// path of (page, index) frames — COW trees have no sibling links, so leaf
/// hops walk back through the recorded branches.
///
/// Noncopyable: a cursor is bound to the transaction that created it; ending
/// the transaction while keeping a cursor is a compile-time error in the
/// public API (the transaction is borrowed for the cursor's lifetime).
///
/// Positions index a snapshot taken at creation (`meta`); cursors over a
/// write context observe the state as of their creation point and must be
/// recreated after further mutations.
public struct Cursor<R: PageResolver>: ~Copyable {
  @usableFromInline let resolver: R
  @usableFromInline let tree: TreeHandle
  /// One frame per level, root first. Branch frames hold the child position
  /// (-1 = leftmost link); the final frame is the leaf cell index.
  @usableFromInline var stack: [(pageNo: UInt64, index: Int)] = []
  public private(set) var isValid = false

  public init(resolver: R, meta: Meta) {
    self.init(resolver: resolver, tree: meta.mainTree)
  }

  public init(resolver: R, tree: TreeHandle) {
    self.resolver = resolver
    self.tree = tree
    self.stack.reserveCapacity(Int(tree.depth) + 1)
  }

  // MARK: - Positioning

  public enum Edge: Sendable {
    case first
    case last
  }

  /// Positions at the lower bound of `key` (first entry ≥ key).
  /// Returns true exactly when the key itself is present.
  public mutating func seek(_ key: UnsafeRawBufferPointer) throws(DBError) -> Bool {
    stack.removeAll(keepingCapacity: true)
    isValid = false
    guard tree.rootPage != 0 else { return false }

    var pageNo = tree.rootPage
    var level = tree.depth
    while level > 1 {
      let page = unsafe try resolver.resolvePage(pageNo)
      guard unsafe PageHeader.pageType(page) == .branch else {
        throw DBError.corruptPage(pageNo: pageNo)
      }
      let slot = unsafe Node.branchChildSlot(page, key: key)
      stack.append((pageNo, slot))
      pageNo = unsafe slot < 0 ? PageHeader.link(page) : Node.branchChild(page, slot)
      level -= 1
    }
    let leaf = unsafe try resolver.resolvePage(pageNo)
    guard unsafe PageHeader.pageType(leaf) == .leaf else {
      throw DBError.corruptPage(pageNo: pageNo)
    }
    let (index, exact) = unsafe Node.search(leaf, key: key)
    stack.append((pageNo, index))
    isValid = true
    if unsafe index == PageHeader.cellCount(leaf) {
      // Lower bound lies in a later leaf (or past the end).
      isValid = try stepLeaf(direction: +1)
    }
    return exact && isValid
  }

  /// Like `seek`, but for *ascending* access: when the cursor is already
  /// positioned and the target lies within the current leaf's key range, it
  /// searches that leaf directly and skips the root→leaf descent. Otherwise it
  /// falls back to a full `seek`. Provably equivalent to `seek` — the fast path
  /// runs only when the key is bounded by the current leaf's first/last key,
  /// where `Node.search` (the same primitive `seek` ends with) is authoritative.
  public mutating func seekForward(_ key: UnsafeRawBufferPointer) throws(DBError) -> Bool {
    if isValid, let top = stack.last {
      let leaf = unsafe try resolver.resolvePage(top.pageNo)
      let count = unsafe PageHeader.cellCount(leaf)
      if unsafe PageHeader.pageType(leaf) == .leaf, count > 0 {
        let firstKey = unsafe Node.leafCell(leaf, 0).key
        let lastKey = unsafe Node.leafCell(leaf, count - 1).key
        if unsafe Node.compare(key, firstKey) >= 0, unsafe Node.compare(key, lastKey) <= 0 {
          let (index, exact) = unsafe Node.search(leaf, key: key)
          stack[stack.count - 1].index = index
          isValid = true
          return exact
        }
      }
    }
    return unsafe try seek(key)
  }

  @discardableResult
  public mutating func move(to edge: Edge) throws(DBError) -> Bool {
    stack.removeAll(keepingCapacity: true)
    isValid = false
    guard tree.rootPage != 0 else { return false }
    try descend(from: tree.rootPage, level: tree.depth, edge: edge)
    let (leafNo, index) = stack[stack.count - 1]
    let leaf = unsafe try resolver.resolvePage(leafNo)
    isValid = unsafe index >= 0 && index < PageHeader.cellCount(leaf)
    return isValid
  }

  @discardableResult
  public mutating func next() throws(DBError) -> Bool {
    guard isValid else { return false }
    let top = stack.count - 1
    let leaf = unsafe try resolver.resolvePage(stack[top].pageNo)
    if unsafe stack[top].index + 1 < PageHeader.cellCount(leaf) {
      stack[top].index += 1
      return true
    }
    isValid = try stepLeaf(direction: +1)
    return isValid
  }

  @discardableResult
  public mutating func prev() throws(DBError) -> Bool {
    guard isValid else { return false }
    let top = stack.count - 1
    if stack[top].index - 1 >= 0 {
      stack[top].index -= 1
      return true
    }
    isValid = try stepLeaf(direction: -1)
    return isValid
  }

  // MARK: - Access

  /// Scoped zero-copy access to the current entry.
  public mutating func withCurrent<T>(
    _ body: (UnsafeRawBufferPointer, BTree.ValueRef) throws(DBError) -> T
  ) throws(DBError) -> T? {
    guard isValid else { return nil }
    let (leafNo, index) = stack[stack.count - 1]
    let leaf = unsafe try resolver.resolvePage(leafNo)
    let cell = unsafe Node.leafCell(leaf, index)
    if let inline = unsafe cell.inlineValue {
      return unsafe try body(cell.key, .inline(inline))
    }
    return unsafe try body(
      cell.key, .overflow(head: cell.overflowHead, length: Int(cell.overflowLength)))
  }

  public mutating func currentKey() throws(DBError) -> [UInt8]? {
    unsafe try withCurrent { key, _ in unsafe [UInt8](key) }
  }

  /// Materializes the current value (streams overflow chains).
  public mutating func currentValue() throws(DBError) -> [UInt8]? {
    let ref: BTree.ValueRef? = unsafe try withCurrent { _, ref in ref }
    guard let ref else { return nil }
    return try BTree.copyValue(ref, resolver: resolver)
  }

  // MARK: - Internals

  /// Descends from `pageNo` (at `level`) to a leaf, appending frames along
  /// the chosen edge.
  private mutating func descend(
    from pageNo: UInt64, level: UInt16, edge: Edge
  ) throws(DBError) {
    var pageNo = pageNo
    var level = level
    while level > 1 {
      let page = unsafe try resolver.resolvePage(pageNo)
      guard unsafe PageHeader.pageType(page) == .branch else {
        throw DBError.corruptPage(pageNo: pageNo)
      }
      let count = unsafe PageHeader.cellCount(page)
      let slot = edge == .first ? -1 : count - 1
      stack.append((pageNo, slot))
      pageNo = unsafe slot < 0 ? PageHeader.link(page) : Node.branchChild(page, slot)
      level -= 1
    }
    let leaf = unsafe try resolver.resolvePage(pageNo)
    guard unsafe PageHeader.pageType(leaf) == .leaf else {
      throw DBError.corruptPage(pageNo: pageNo)
    }
    unsafe stack.append((pageNo, edge == .first ? 0 : PageHeader.cellCount(leaf) - 1))
  }

  /// Pops to the nearest branch with an unvisited sibling in `direction`,
  /// then descends that subtree's near edge. Returns false past either end.
  private mutating func stepLeaf(direction: Int) throws(DBError) -> Bool {
    let depth = Int(tree.depth)
    stack.removeLast() // leaf frame
    while !stack.isEmpty {
      let frame = stack[stack.count - 1]
      let page = unsafe try resolver.resolvePage(frame.pageNo)
      let nextIndex = frame.index + direction
      let limit = unsafe PageHeader.cellCount(page) - 1
      if nextIndex >= -1 && nextIndex <= limit {
        stack[stack.count - 1].index = nextIndex
        let child = unsafe nextIndex < 0 ? PageHeader.link(page) : Node.branchChild(page, nextIndex)
        let childLevel = UInt16(depth - stack.count)
        try descend(from: child, level: childLevel, edge: direction > 0 ? .first : .last)
        return true
      }
      stack.removeLast()
    }
    return false
  }
}

/// Resolves page numbers to page bytes. Read transactions resolve straight
/// from committed storage; write transactions overlay their dirty table.
public protocol PageResolver {
  func resolvePage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer
}

/// Committed-page reader (mmap in production, dictionaries in tests).
public protocol PageSource: AnyObject {
  func page(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer
}

/// Page allocation state for one write transaction. Fresh pages (allocated
/// and freed within the same transaction, never visible to any reader) are
/// recycled immediately; committed pages freed here must wait for readers
/// and are handed to the free-list at commit.
public struct PageAllocator {
  /// Next never-used page (high-water mark, becomes meta.pageCount).
  public var highWater: UInt64
  /// Reusable pages harvested from the free-list (older generations whose
  /// readers are gone) plus same-transaction fresh frees.
  public var pool: [UInt64]
  /// While the free-list serializes itself at commit time, the pool is
  /// frozen (its contents are being written out) and all allocation comes
  /// from the high-water mark.
  public var highWaterOnly = false

  public init(highWater: UInt64, pool: [UInt64] = []) {
    self.highWater = highWater
    self.pool = pool
  }

  public mutating func allocate() -> UInt64 {
    if !highWaterOnly, let reused = pool.popLast() { return reused }
    defer { highWater += 1 }
    return highWater
  }

  /// Allocate bypassing the recycled pool (used by free-list maintenance to
  /// avoid consuming the pool it is itself rebuilding).
  public mutating func allocateHighWater() -> UInt64 {
    defer { highWater += 1 }
    return highWater
  }
}

/// Mutable state of one write transaction. Single-threaded by construction:
/// only the writer loop touches it.
public final class TxnContext: PageResolver, OverflowPager {
  public let source: PageSource
  public var meta: Meta
  public var allocator: PageAllocator
  /// Pages written this transaction (always includes every allocated page).
  public var dirty: [UInt64: PageBuf] = [:]
  /// Committed pages this transaction stopped referencing: reclaimable only
  /// once concurrent readers move past this generation.
  public var pendingFree: [UInt64] = []

  /// Relational state (catalog, handles, sequences), loaded lazily on first
  /// relational use. Value-typed: TxnRestorePoint snapshots it by copy.
  public internal(set) var relation: RelationState?

  /// Group-commit nesting: stacked micro-transactions bump the epoch; pages
  /// dirtied by earlier requests are cloned on first touch so a failing
  /// request can restore them (see RequestUndo).
  var requestEpoch: UInt32 = 0
  var undoReplaced: [(pageNo: UInt64, previous: PageBuf)] = []
  var undoAllocated: [UInt64] = []
  var undoFreedOwned: [(pageNo: UInt64, buf: PageBuf)] = []

  public init(source: PageSource, meta: Meta, pool: [UInt64] = []) {
    self.source = source
    self.meta = meta
    self.allocator = PageAllocator(highWater: meta.pageCount, pool: pool)
  }

  // MARK: - Page access

  public func resolvePage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
    if let buf = dirty[pageNo] { return buf.readOnly }
    return try source.page(pageNo)
  }

  @inline(__always)
  public func owns(_ pageNo: UInt64) -> Bool { dirty[pageNo] != nil }

  /// Brand-new zeroed page owned by this transaction.
  public func allocatePage() -> (pageNo: UInt64, buf: PageBuf) {
    let pageNo = allocator.allocate()
    let buf = PageBuf()
    buf.requestEpoch = requestEpoch
    dirty[pageNo] = buf
    if requestEpoch != 0 { undoAllocated.append(pageNo) }
    return (pageNo, buf)
  }

  /// COW fault-in: returns a mutable buffer for `pageNo`. If the page is
  /// committed, it is copied to a freshly allocated page number (the old one
  /// goes to pendingFree) — COW-once-per-transaction. Under group commit,
  /// pages owned by an *earlier request* are additionally cloned on first
  /// touch so the current request can be rolled back alone.
  public func shadow(_ pageNo: UInt64) throws(DBError) -> (pageNo: UInt64, buf: PageBuf) {
    if let buf = dirty[pageNo] {
      if requestEpoch != 0, buf.requestEpoch != requestEpoch {
        let clone = PageBuf(copying: buf.readOnly)
        clone.requestEpoch = requestEpoch
        dirty[pageNo] = clone
        undoReplaced.append((pageNo: pageNo, previous: buf))
        return (pageNo, clone)
      }
      return (pageNo, buf)
    }
    let copy = PageBuf(copying: try source.page(pageNo))
    copy.requestEpoch = requestEpoch
    let newNo = allocator.allocate()
    dirty[newNo] = copy
    pendingFree.append(pageNo)
    if requestEpoch != 0 { undoAllocated.append(newNo) }
    return (newNo, copy)
  }

  /// Releases a page this transaction no longer references.
  public func freePage(_ pageNo: UInt64) {
    if let buf = dirty.removeValue(forKey: pageNo) {
      // Never visible to anyone: recycle immediately.
      allocator.pool.append(pageNo)
      if requestEpoch != 0 { undoFreedOwned.append((pageNo: pageNo, buf: buf)) }
    } else {
      pendingFree.append(pageNo)
    }
  }

  // MARK: - Group-commit request nesting

  /// Starts a new stacked micro-transaction scope.
  func beginRequestScope() {
    requestEpoch &+= 1
    if requestEpoch == 0 { requestEpoch = 1 }
    undoReplaced.removeAll(keepingCapacity: true)
    undoAllocated.removeAll(keepingCapacity: true)
    undoFreedOwned.removeAll(keepingCapacity: true)
  }

  /// Rolls back everything the current request scope did to the page state.
  /// Scalar state (meta, pendingFree, pool, highWater) is restored by the
  /// caller's TxnRestorePoint.
  func rollbackRequestScope() {
    for entry in undoReplaced { dirty[entry.pageNo] = entry.previous }
    for pageNo in undoAllocated { dirty.removeValue(forKey: pageNo) }
    for entry in undoFreedOwned { dirty[entry.pageNo] = entry.buf }
  }

  // MARK: - OverflowPager

  public func allocateOverflowPage() throws(DBError) -> (pageNo: UInt64, buffer: UnsafeMutableRawBufferPointer) {
    let (pageNo, buf) = allocatePage()
    return (pageNo, buf.raw)
  }

  public func readOverflowPage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
    try resolvePage(pageNo)
  }

  public func freeOverflowPage(_ pageNo: UInt64) throws(DBError) {
    freePage(pageNo)
  }
}

/// Read-side resolver over committed pages only.
public struct CommittedResolver: PageResolver {
  public let source: PageSource
  public init(source: PageSource) { self.source = source }
  @inline(__always)
  public func resolvePage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
    try source.page(pageNo)
  }
}

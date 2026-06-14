/// Resolves page numbers to page bytes. Read transactions resolve straight
/// from committed storage; write transactions overlay their dirty table.
public protocol PageResolver {
  func resolvePage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer
  /// Advisory readahead for an upcoming contiguous page run (forward scans).
  func prefetch(fromPage: UInt64, count: Int)
  /// Configured scan readahead window in pages a cursor should keep in flight
  /// (0 disables). Forward scans read this once at creation.
  var prefetchWindow: Int { get }
}

extension PageResolver {
  /// Default: prefetch is a no-op (write contexts and test resolvers don't
  /// scan-prefetch; only the mapped committed reader forwards it).
  @inline(__always)
  public func prefetch(fromPage: UInt64, count: Int) {}
  @inline(__always)
  public var prefetchWindow: Int { 0 }
}

/// Committed-page reader (mmap in production, dictionaries in tests).
public protocol PageSource: AnyObject {
  func page(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer
  func prefetch(fromPage: UInt64, count: Int)
  var prefetchWindow: Int { get }
}

extension PageSource {
  @inline(__always)
  public func prefetch(fromPage: UInt64, count: Int) {}
  @inline(__always)
  public var prefetchWindow: Int { 0 }
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

  /// Reusable encode buffers for the insert path: one for the row record, one for
  /// each index entry key (used sequentially). `putBytes` copies the bytes into
  /// the page, so reusing the buffer across rows in a transaction avoids a fresh
  /// allocation per row. Query/read paths never touch these.
  var recordScratch: [UInt8] = []
  var indexKeyScratch: [UInt8] = []
  /// Warm rightmost-leaf append cache per table tree (keyed by tableId), used by
  /// the opt-in `appendCursor` insert path. Writer-confined; cleared on request
  /// rollback (below). The per-entry `rootPage` guard catches every other tree
  /// mutation (a non-append re-shadows the root), so a stale entry never appends.
  var appendCache: [UInt32: BTree.AppendCache] = [:]
  /// Whether the opt-in `appendCursor` insert fast path is active for this
  /// transaction (`DatabaseOptions.execution.insert == .appendCursor`); set once
  /// at ctx creation. Default off → the proven descent path.
  var appendCursorEnabled = false

  /// Relational state (catalog, handles, sequences), loaded lazily on first
  /// relational use. Value-typed: TxnRestorePoint snapshots it by copy.
  public internal(set) var relation: RelationState?

  /// Active NEW/OLD row frame while a trigger body executes (M5/F5). The write
  /// path consults it so trigger-body expressions can read `new.col`/`old.col`;
  /// nil outside a trigger. Stacked frames restore the prior frame on return.
  var triggerFrame: TriggerFrame?
  /// Trigger recursion depth: bumped around each fired trigger body so a
  /// self-referential trigger errors instead of looping forever.
  var triggerDepth: UInt32 = 0

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
    if let buf = dirty[pageNo] { return unsafe buf.readOnly }
    // Committed pages live in [0, meta.pageCount); a higher number is a corrupt
    // in-page pointer that would otherwise read mapped-but-uncommitted (zeroed)
    // space without faulting (integrity R2). Pages allocated this transaction
    // are in `dirty` above, so they bypass this bound.
    guard pageNo < meta.pageCount else { throw DBError.corruptPage(pageNo: pageNo) }
    return unsafe try source.page(pageNo)
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
        let clone = unsafe PageBuf(copying: buf.readOnly)
        clone.requestEpoch = requestEpoch
        dirty[pageNo] = clone
        undoReplaced.append((pageNo: pageNo, previous: buf))
        return (pageNo, clone)
      }
      return (pageNo, buf)
    }
    let copy = unsafe PageBuf(copying: try source.page(pageNo))
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
    // The append cache may point at a leaf whose appends this scope just undid;
    // drop it so the next append re-establishes it from the restored tree.
    appendCache.removeAll(keepingCapacity: true)
  }

  // MARK: - OverflowPager

  public func allocateOverflowPage() throws(DBError) -> (pageNo: UInt64, buffer: UnsafeMutableRawBufferPointer) {
    let (pageNo, buf) = allocatePage()
    return unsafe (pageNo, buf.raw)
  }

  public func readOverflowPage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
    unsafe try resolvePage(pageNo)
  }

  public func freeOverflowPage(_ pageNo: UInt64) throws(DBError) {
    freePage(pageNo)
  }
}

/// Read-side resolver over committed pages only.
public struct CommittedResolver: PageResolver {
  public let source: PageSource
  /// Snapshot's committed high-water: a committed tree never references a page
  /// number ≥ pageCount, so anything beyond it is a corrupt in-page pointer
  /// (which would read mapped-but-uncommitted space without faulting). `.max`
  /// leaves the bound off for low-level resolvers built without a meta.
  public let pageCount: UInt64
  /// Verify each resolved page's checksum before use (opt-in; off on the hot
  /// path). Catches the full corruption class — a tampered cellCount/keyLen
  /// changes the page bytes, so the stored XXH64 no longer matches.
  public let verifyChecksums: Bool

  public init(source: PageSource, pageCount: UInt64 = .max, verifyChecksums: Bool = false) {
    self.source = source
    self.pageCount = pageCount
    self.verifyChecksums = verifyChecksums
  }
  @inline(__always)
  public func resolvePage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
    guard pageNo < pageCount else { throw DBError.corruptPage(pageNo: pageNo) }
    let page = unsafe try source.page(pageNo)
    if verifyChecksums, unsafe !PageHeader.verifyChecksum(page, pageNo: pageNo) {
      throw DBError.corruptPage(pageNo: pageNo)
    }
    return unsafe page
  }
  @inline(__always)
  public func prefetch(fromPage: UInt64, count: Int) {
    source.prefetch(fromPage: fromPage, count: count)
  }
  @inline(__always)
  public var prefetchWindow: Int { source.prefetchWindow }
}

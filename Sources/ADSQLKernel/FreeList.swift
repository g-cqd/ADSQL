/// Page reclamation. Freed pages are recorded in a second COW B+tree (the
/// free tree) keyed by when they become reusable:
///
///   key   = availAfterGen u64 BE ++ seq u16 BE   (memcmp order = numeric)
///   value = count u32 LE ++ varint(first page) ++ varint(gaps...)
///
/// Semantics: pages in an entry with `availAfterGen == E` were dropped by
/// the commit of generation E — trees ≥ E no longer reference them. They are
/// safe to reuse once (a) no reader sits below E and (b) E is committed.
/// (b) also covers crash recovery: barrier ordering means that once a later
/// transaction's writes reach disk, recovery can never land before E.
/// `availAfterGen == 0` marks pages that were never visible to any committed
/// tree (the written-back unused pool) — always harvestable.
///
/// Entries are chunked so values stay inline (no overflow chains inside the
/// free tree), which keeps commit-time self-serialization convergent.
public enum FreeList {
  public static let pagesPerEntry = 400
  static let keySize = 10

  // MARK: - Codecs

  static func entryKey(gen: UInt64, seq: UInt16) -> [UInt8] {
    var key = [UInt8](repeating: 0, count: keySize)
    withUnsafeBytes(of: gen.bigEndian) { key.replaceSubrange(0..<8, with: $0) }
    withUnsafeBytes(of: seq.bigEndian) { key.replaceSubrange(8..<10, with: $0) }
    return key
  }

  static func decodeKey(_ key: UnsafeRawBufferPointer) -> (gen: UInt64, seq: UInt16)? {
    guard key.count == keySize else { return nil }
    let gen = UInt64(bigEndian: key.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
    let seq = UInt16(bigEndian: key.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
    return (gen, seq)
  }

  @inline(__always)
  static func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
    Varint.append(value, to: &bytes)
  }

  @inline(__always)
  static func readVarint(_ bytes: UnsafeRawBufferPointer, _ offset: inout Int) -> UInt64? {
    Varint.read(bytes, &offset)
  }

  static let fixedWidthFlag: UInt32 = 0x8000_0000

  /// Fixed-width placeholder buffer for `capacity` pages: size is
  /// independent of contents, so values can be patched in place after
  /// allocation settles (the LMDB reserve-then-backfill trick).
  static func fixedWidthPlaceholder(capacity: Int) -> [UInt8] {
    [UInt8](repeating: 0, count: 4 + 8 * capacity)
  }

  /// Patches a fixed-width buffer with the final page list (count ≤ capacity).
  static func patchFixedWidth(_ buffer: UnsafeMutableRawBufferPointer, pages: ArraySlice<UInt64>) {
    precondition(buffer.count >= 4 + 8 * pages.count)
    buffer.storeLE32(UInt32(pages.count) | fixedWidthFlag, at: 0)
    var offset = 4
    for page in pages {
      buffer.storeLE64(page, at: offset)
      offset += 8
    }
  }

  /// `pages` must be sorted ascending and unique.
  static func encodePages(_ pages: ArraySlice<UInt64>) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(4 + pages.count * 3)
    withUnsafeBytes(of: UInt32(pages.count).littleEndian) { out.append(contentsOf: $0) }
    var previous: UInt64 = 0
    var first = true
    for page in pages {
      appendVarint(first ? page : page - previous, to: &out)
      previous = page
      first = false
    }
    return out
  }

  static func decodePages(_ bytes: UnsafeRawBufferPointer) throws(DBError) -> [UInt64] {
    guard bytes.count >= 4 else { throw DBError.integrityFailure("free entry too short") }
    let rawCount = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
    if rawCount & fixedWidthFlag != 0 {
      let count = Int(rawCount & ~fixedWidthFlag)
      guard bytes.count >= 4 + 8 * count else {
        throw DBError.integrityFailure("fixed-width free entry truncated")
      }
      var pages: [UInt64] = []
      pages.reserveCapacity(count)
      for i in 0..<count {
        pages.append(UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 4 + 8 * i, as: UInt64.self)))
      }
      return pages
    }
    let count = Int(rawCount)
    var pages: [UInt64] = []
    pages.reserveCapacity(count)
    var offset = 4
    var previous: UInt64 = 0
    for i in 0..<count {
      guard let delta = readVarint(bytes, &offset) else {
        throw DBError.integrityFailure("free entry varint truncated")
      }
      previous = i == 0 ? delta : previous + delta
      pages.append(previous)
    }
    return pages
  }

  // MARK: - Harvest (transaction start)

  /// Consumes every entry with `availAfterGen <= limit` into the allocator
  /// pool. `limit` must be min(reader generations, committed generation).
  /// Returns the number of pages harvested.
  @discardableResult
  public static func harvest(ctx: TxnContext, upTo limit: UInt64) throws(DBError) -> Int {
    var free = ctx.meta.freeTree
    var harvested = 0
    while free.rootPage != 0 {
      // Re-seek the first entry each round: deletes reshape the tree.
      var cursor = Cursor(resolver: ctx, tree: free)
      guard try cursor.move(to: .first) else { break }
      let result: (key: [UInt8], pages: [UInt64])? = try cursor.withCurrent {
        (key, ref) throws(DBError) in
        guard let decoded = decodeKey(key), decoded.gen <= limit else { return nil }
        guard case .inline(let value) = ref else {
          throw DBError.integrityFailure("free entry value must be inline")
        }
        return (key: [UInt8](key), pages: try decodePages(value))
      } ?? nil
      guard let result else { break }

      // Pool the pages BEFORE deleting the entry: the delete's own COW then
      // recycles a just-harvested page instead of growing the file.
      ctx.allocator.pool.append(contentsOf: result.pages)
      harvested += result.pages.count
      var failure: DBError?
      result.key.withUnsafeBytes { keyBytes in
        do throws(DBError) {
          _ = try BTree.delete(ctx: ctx, tree: &free, key: keyBytes)
        } catch {
          failure = error
        }
      }
      if let failure { throw failure }
    }
    ctx.meta.freeTree = free
    return harvested
  }

  // MARK: - Serialize (commit time)

  /// Writes this transaction's page bookkeeping into the free tree:
  /// `pendingFree` under the committing generation, leftover pool pages
  /// under generation 0. Runs to a fixed point because serialization itself
  /// shadows free-tree pages (which extends `pendingFree`).
  ///
  /// Requires `harvest` to have run at transaction start (gen-0 keys are
  /// assumed consumed) and must be the last mutation before commit.
  public static func serialize(ctx: TxnContext) throws(DBError) {
    let commitGen = ctx.meta.generation + 1
    var free = ctx.meta.freeTree
    var genSeq: UInt16 = 0
    var writtenPendingFree = 0
    var rounds = 0

    func drainPendingFree() throws(DBError) -> Bool {
      guard writtenPendingFree < ctx.pendingFree.count else { return false }
      let fresh = ctx.pendingFree[writtenPendingFree...].sorted()
      writtenPendingFree = ctx.pendingFree.count
      var index = 0
      while index < fresh.count {
        let chunk = fresh[index..<min(index + pagesPerEntry, fresh.count)]
        try putEntry(ctx, &free, gen: commitGen, seq: genSeq, pages: chunk)
        genSeq += 1
        index += chunk.count
      }
      return true
    }

    // Phase 1: record pendingFree with the pool still available — free-tree
    // COW draws on recycled pages instead of growing the file. Each round
    // may shadow more committed free-tree pages (extending pendingFree);
    // after the first round the spine is transaction-owned, so this
    // converges immediately.
    while try drainPendingFree() {
      rounds += 1
      precondition(rounds <= 8, "free-list serialization did not converge")
    }

    // Phase 2: freeze the pool and persist the leftover as generation 0
    // (always harvestable). Writing it can itself shadow pages or split
    // nodes (high-water only now); drain any tail that produces.
    ctx.allocator.highWaterOnly = true
    defer { ctx.allocator.highWaterOnly = false }
    let pool = ctx.allocator.pool.sorted()
    ctx.allocator.pool.removeAll()
    var zeroSeq: UInt16 = 0
    var index = 0
    while index < pool.count {
      let chunk = pool[index..<min(index + pagesPerEntry, pool.count)]
      try putEntry(ctx, &free, gen: 0, seq: zeroSeq, pages: chunk)
      zeroSeq += 1
      index += chunk.count
    }
    while try drainPendingFree() {
      rounds += 1
      precondition(rounds <= 12, "free-list serialization did not converge")
    }

    ctx.meta.freeTree = free
  }

  private static func putEntry(
    _ ctx: TxnContext, _ tree: inout TreeHandle,
    gen: UInt64, seq: UInt16, pages: ArraySlice<UInt64>
  ) throws(DBError) {
    guard !pages.isEmpty else { return }
    let key = entryKey(gen: gen, seq: seq)
    let value = encodePages(pages)
    var failure: DBError?
    key.withUnsafeBytes { keyBytes in
      value.withUnsafeBytes { valueBytes in
        do throws(DBError) {
          try BTree.put(ctx: ctx, tree: &tree, key: keyBytes, value: valueBytes)
        } catch {
          failure = error
        }
      }
    }
    if let failure { throw failure }
  }

  // MARK: - Inspection (integrity, tests)

  /// Every page currently listed as free, with its availability generation.
  public static func allListedPages(
    resolver: some PageResolver, tree: TreeHandle
  ) throws(DBError) -> [(gen: UInt64, page: UInt64)] {
    var listed: [(gen: UInt64, page: UInt64)] = []
    try BTree.forEach(resolver: resolver, tree: tree) { (key, ref) throws(DBError) in
      guard let decoded = decodeKey(key) else {
        throw DBError.integrityFailure("malformed free-list key")
      }
      guard case .inline(let value) = ref else {
        throw DBError.integrityFailure("free entry value must be inline")
      }
      for page in try decodePages(value) {
        listed.append((gen: decoded.gen, page: page))
      }
    }
    return listed
  }
}

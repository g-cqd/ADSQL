import Darwin

public struct IntegrityReport: Sendable {
  public var generation: UInt64
  public var pageCount: UInt64
  public var kvCount: UInt64
  public var treeDepth: UInt16
  public var mainTreePages: Int
  public var freeTreePages: Int
  public var overflowPages: Int
  public var freeListedPages: Int
  public var tableCount: Int = 0
  public var indexCount: Int = 0
  public var relationTreePages: Int = 0
}

/// Whole-file verification: both trees structurally valid with checksums,
/// and the page-liveness invariant — {metas} ∪ main pages ∪ free-tree pages
/// ∪ free-listed pages == [0, pageCount), pairwise disjoint. Any deviation
/// (corruption, leak, double-use) throws.
public enum Integrity {
  public static func check(
    resolver: some PageResolver, meta: Meta, verifyChecksums: Bool = true,
    deep: Bool = false
  ) throws(DBError) -> IntegrityReport {
    let main = try BTree.validate(
      resolver: resolver, tree: meta.mainTree, verifyChecksums: verifyChecksums)
    let free = try BTree.validate(
      resolver: resolver, tree: meta.freeTree, verifyChecksums: verifyChecksums)

    var seen = Set<UInt64>([0, 1])
    func claim(_ page: UInt64, _ what: @autoclosure () -> String) throws(DBError) {
      guard page >= Format.firstDataPage, page < meta.pageCount else {
        throw DBError.integrityFailure("\(what()): page \(page) out of bounds")
      }
      guard seen.insert(page).inserted else {
        throw DBError.integrityFailure("\(what()): page \(page) claimed twice")
      }
    }
    for page in main.reachablePages { try claim(page, "main tree") }
    for page in free.reachablePages { try claim(page, "free tree") }

    // Relational trees: every table and index hangs off the catalog.
    let relationState = try Relation.loadState(resolver: resolver, mainTree: meta.mainTree)
    var relationTreePages = 0
    for name in relationState.tableRecords.keys.sorted() {
      let record = relationState.tableRecords[name]!
      let report = try BTree.validate(
        resolver: resolver, tree: record.handle, verifyChecksums: verifyChecksums)
      for page in report.reachablePages { try claim(page, "table \(name)") }
      relationTreePages += report.reachablePages.count
    }
    for name in relationState.indexRecords.keys.sorted() {
      let record = relationState.indexRecords[name]!
      let report = try BTree.validate(
        resolver: resolver, tree: record.handle, verifyChecksums: verifyChecksums)
      for page in report.reachablePages { try claim(page, "index \(name)") }
      relationTreePages += report.reachablePages.count
    }
    // FTS virtual tables own three B+trees (dictionary / postings / stats); they
    // hang off the catalog FTS record just like a table/index handle.
    for name in relationState.ftsRecords.keys.sorted() {
      let record = relationState.ftsRecords[name]!
      for (label, handle) in [
        ("dict", record.dict), ("postings", record.postings), ("stats", record.stats),
      ] {
        let report = try BTree.validate(
          resolver: resolver, tree: handle, verifyChecksums: verifyChecksums)
        for page in report.reachablePages { try claim(page, "fts \(name).\(label)") }
        relationTreePages += report.reachablePages.count
      }
    }

    var freeListed = 0
    for entry in try FreeList.allListedPages(resolver: resolver, tree: meta.freeTree) {
      try claim(entry.page, "free entry gen \(entry.gen)")
      freeListed += 1
    }
    guard seen.count == Int(meta.pageCount) else {
      let missing = (0..<meta.pageCount).filter { !seen.contains($0) }
      throw DBError.integrityFailure(
        "leaked pages: \(Array(missing.prefix(20))) (\(missing.count) of \(meta.pageCount))")
    }

    if deep {
      try deepCheck(resolver: resolver, state: relationState)
    }

    return IntegrityReport(
      generation: meta.generation,
      pageCount: meta.pageCount,
      kvCount: meta.kvCount,
      treeDepth: meta.treeDepth,
      mainTreePages: main.reachablePages.count,
      freeTreePages: free.reachablePages.count,
      overflowPages: main.overflowPages,
      freeListedPages: freeListed,
      tableCount: relationState.tableRecords.count,
      indexCount: relationState.indexRecords.count,
      relationTreePages: relationTreePages)
  }

  /// Deep mode: index ⇄ row bijection. Every index entry must resolve to a
  /// live row whose encoded column values reproduce the entry key exactly,
  /// and per-table entry counts must equal row counts for every index.
  static func deepCheck(
    resolver: some PageResolver, state: RelationState
  ) throws(DBError) -> Void {
    for indexName in state.indexRecords.keys.sorted() {
      let index = state.indexRecords[indexName]!
      guard let tableName = state.tableName(for: index.tableId),
        let table = state.tableRecords[tableName]
      else {
        throw DBError.integrityFailure("index \(indexName) references a missing table")
      }
      guard index.handle.count == table.handle.count else {
        throw DBError.integrityFailure(
          "index \(indexName) has \(index.handle.count) entries; table "
            + "\(tableName) has \(table.handle.count) rows")
      }

      var entries = 0
      var cursor = Cursor(resolver: resolver, tree: index.handle)
      var positioned = try cursor.move(to: .first)
      while positioned {
        let entryKey: [UInt8]? = unsafe try cursor.withCurrent { (key, _) throws(DBError) in
          unsafe [UInt8](key)
        }
        guard let entryKey else { break }
        guard let rowid = entryKey.withUnsafeBytes({ unsafe KeyCodec.rowid(fromSuffixOf: $0) }) else {
          throw DBError.integrityFailure("index \(indexName): malformed entry key")
        }
        guard
          let recordBytes = try Relation.getBytes(
            resolver, table.handle, key: KeyCodec.rowKey(rowid))
        else {
          throw DBError.integrityFailure(
            "index \(indexName): dangling entry for rowid \(rowid)")
        }
        let row = try Relation.materializeRow(
          table: table, rowid: rowid, recordBytes: recordBytes)
        let expected = try Relation.indexEntryKey(
          index: index, table: table, row: row, rowid: rowid)
        guard expected == entryKey else {
          throw DBError.integrityFailure(
            "index \(indexName): entry for rowid \(rowid) does not match the row")
        }
        entries += 1
        positioned = try cursor.next()
      }
      guard UInt64(entries) == index.handle.count else {
        throw DBError.integrityFailure(
          "index \(indexName): walked \(entries) entries, handle says \(index.handle.count)")
      }
    }
  }
}

extension Database {
  /// Verifies the newest committed generation end to end (checksums,
  /// structure, page liveness; `deep` adds index ⇄ row bijection). Runs as
  /// a reader: the writer is unaffected.
  public func verifyIntegrity(deep: Bool = false) throws(DBError) -> IntegrityReport {
    let meta = try beginRead()
    defer { endRead(generation: meta.generation) }
    return try Integrity.check(
      resolver: CommittedResolver(source: pager), meta: meta, deep: deep)
  }

  /// O(1) atomic snapshot via APFS clonefile(2). Quiesces the writer for
  /// the (instant) duration of the clone, so the snapshot is exactly the
  /// newest committed generation.
  public func snapshot(to destination: String) throws(DBError) {
    var result: Result<Void, DBError> = .success(())
    writerThread.sync {
      let status = path.withCString { src in
        destination.withCString { dst in
          unsafe clonefile(src, dst, 0)
        }
      }
      if status != 0 {
        result = .failure(
          errno == EEXIST
            ? DBError.snapshotDestinationExists
            : DBError.io(errno: errno, op: "clonefile(\(destination))"))
      }
    }
    try result.get()
  }
}

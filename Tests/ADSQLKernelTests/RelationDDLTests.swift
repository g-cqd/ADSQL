import Dispatch
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

private func documentsTable(_ name: String = "documents") -> TableDefinition {
  TableDefinition(
    name,
    columns: [
      ColumnDefinition("id", .integer, notNull: true),
      ColumnDefinition("key", .text, notNull: true),
      ColumnDefinition("title", .text, notNull: true, collation: .nocase),
      ColumnDefinition("framework", .text),
      ColumnDefinition("is_deprecated", .integer, defaultValue: .value(.integer(0))),
      ColumnDefinition("created_at", .text, defaultValue: .datetimeNow),
    ],
    primaryKey: .rowidAlias(column: "id", autoincrement: true))
}

@Suite("Relation DDL")
struct RelationDDLTests {
  @Test func createPersistsAcrossReopen() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = dir.file("ddl.adsql")
    do {
      let db = try Database.open(at: path)
      try db.writeSync { (txn) throws(DBError) in
        try txn.createTable(documentsTable())
        try txn.createIndex(IndexDefinition("idx_documents_key", on: "documents", columns: ["key"], unique: true))
        try txn.createIndex(IndexDefinition("idx_documents_framework", on: "documents", columns: ["framework"]))
      }
      let schema = try db.read { (txn) throws(DBError) in try txn.schema() }
      #expect(schema.tables["documents"] == documentsTable())
      #expect(schema.indexes.count == 2)
      #expect(schema.indexes["idx_documents_key"]?.unique == true)
      #expect(schema.catalogVersion == 1)
      db.close()
    }

    let db = try Database.open(at: path)
    defer { db.close() }
    let schema = try db.read { (txn) throws(DBError) in try txn.schema() }
    #expect(schema.tables["documents"] == documentsTable())
    #expect(schema.indexes(on: "documents").map(\.name)
      == ["idx_documents_framework", "idx_documents_key"])
    let report = try db.verifyIntegrity()
    #expect(report.tableCount == 1)
    #expect(report.indexCount == 2)
  }

  @Test func versionBumpsOnDDLOnly() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("ver.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(documentsTable())
    }
    let after = try db.read { (txn) throws(DBError) in try txn.schema().catalogVersion }
    #expect(after == 1)

    // Plain KV writes must not bump the catalog version.
    try db.writeSync { (txn) throws(DBError) in try txn.put([1], [1]) }
    let afterKV = try db.read { (txn) throws(DBError) in try txn.schema().catalogVersion }
    #expect(afterKV == 1)

    // Two DDL ops in ONE transaction bump it once.
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(documentsTable("t2"))
      try txn.createIndex(IndexDefinition("i2", on: "t2", columns: ["key"]))
    }
    let afterTwo = try db.read { (txn) throws(DBError) in try txn.schema().catalogVersion }
    #expect(afterTwo == 2)
  }

  @Test func ddlErrors() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("err.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in try txn.createTable(documentsTable()) }

    #expect(throws: DBError.tableExists("documents")) {
      try db.writeSync { (txn) throws(DBError) in try txn.createTable(documentsTable()) }
    }
    #expect(throws: DBError.noSuchTable("ghost")) {
      try db.writeSync { (txn) throws(DBError) in try txn.dropTable("ghost") }
    }
    #expect(throws: DBError.noSuchTable("ghost")) {
      try db.writeSync { (txn) throws(DBError) in
        try txn.createIndex(IndexDefinition("ix", on: "ghost", columns: ["key"]))
      }
    }
    #expect(throws: DBError.noSuchIndex("ghost")) {
      try db.writeSync { (txn) throws(DBError) in try txn.dropIndex("ghost") }
    }
    // FK to a missing parent.
    #expect(throws: DBError.noSuchTable("missing_parent")) {
      try db.writeSync { (txn) throws(DBError) in
        try txn.createTable(TableDefinition(
          "child", columns: [ColumnDefinition("doc_id", .integer)],
          foreignKeys: [ForeignKey(childColumns: ["doc_id"], parentTable: "missing_parent", onDelete: .cascade)]))
      }
    }
    // Dropping a referenced parent is blocked.
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(TableDefinition(
        "sections", columns: [ColumnDefinition("document_id", .integer)],
        foreignKeys: [ForeignKey(childColumns: ["document_id"], parentTable: "documents", onDelete: .cascade)]))
    }
    #expect(throws: DBError.foreignKeyViolation(table: "sections")) {
      try db.writeSync { (txn) throws(DBError) in try txn.dropTable("documents") }
    }
    // Failed DDL persists nothing.
    let schema = try db.read { (txn) throws(DBError) in try txn.schema() }
    #expect(Set(schema.tables.keys) == ["documents", "sections"])
  }

  @Test func dropReclaimsCatalogState() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("drop.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(documentsTable())
      try txn.createIndex(IndexDefinition("ik", on: "documents", columns: ["key"]))
    }
    try db.writeSync { (txn) throws(DBError) in
      try txn.dropTable("documents") // drops its index too
    }
    let schema = try db.read { (txn) throws(DBError) in try txn.schema() }
    #expect(schema.tables.isEmpty)
    #expect(schema.indexes.isEmpty)
    let report = try db.verifyIntegrity()
    #expect(report.tableCount == 0)
    #expect(report.indexCount == 0)

    // Name is reusable, ids advance.
    try db.writeSync { (txn) throws(DBError) in try txn.createTable(documentsTable()) }
    let again = try db.read { (txn) throws(DBError) in try txn.schema() }
    #expect(again.tables["documents"] != nil)
  }

  @Test func reservedKeysAreRejectedAndHidden() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("resv.adsql"))
    defer { db.close() }
    #expect(throws: DBError.reservedKey) {
      try db.writeSync { (txn) throws(DBError) in try txn.put([0x00, 0x41], [1]) }
    }
    #expect(throws: DBError.reservedKey) {
      try db.read { (txn) throws(DBError) in _ = try txn.get([0x00]) }
    }
    // System rows are invisible to KV iteration.
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(documentsTable())
      try txn.put(Array("user-key".utf8), [7])
    }
    let seen = try db.read { (txn) throws(DBError) in
      var keys: [[UInt8]] = []
      try txn.forEach { key, _ in keys.append(key) }
      return keys
    }
    #expect(seen == [Array("user-key".utf8)])
  }

  @Test func schemaCacheIsMVCCCorrect() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("mvcc.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in try txn.createTable(documentsTable()) }

    let readerEntered = DispatchSemaphore(value: 0)
    let ddlDone = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var pinnedTables: Set<String> = []
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
      try? db.read { (txn) throws(DBError) in
        readerEntered.signal()
        ddlDone.wait()
        // Snapshot from BEFORE the DDL: must not see table t2.
        pinnedTables = Set(try txn.schema().tables.keys)
      }
    }
    readerEntered.wait()
    try db.writeSync { (txn) throws(DBError) in try txn.createTable(documentsTable("t2")) }
    // Prime the cache with the NEW schema before releasing the old reader.
    let fresh = try db.read { (txn) throws(DBError) in Set(try txn.schema().tables.keys) }
    #expect(fresh == ["documents", "t2"])
    ddlDone.signal()
    group.wait()
    #expect(pinnedTables == ["documents"], "old snapshot leaked a newer schema")
  }

  @Test func failingDDLRequestRollsBackInBatch() async throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("batchddl.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in try txn.createTable(documentsTable()) }

    let blocker = DispatchSemaphore(value: 0)
    let blockerTask = Task.detached {
      try? db.writeSync { (txn) throws(DBError) in
        try txn.put(Array("warm".utf8), [0])
        blocker.wait()
      }
    }
    async let first: Void = db.write { (txn) throws(DBError) in
      try txn.createTable(documentsTable("ok_table"))
    }
    async let poisoned: Void = db.write { (txn) throws(DBError) in
      try txn.createTable(documentsTable("ghost_table"))
      try txn.createTable(documentsTable()) // duplicate → throws, rolls back ghost_table
    }
    async let second: Void = db.write { (txn) throws(DBError) in
      try txn.createIndex(IndexDefinition("ok_idx", on: "ok_table", columns: ["key"]))
    }
    blocker.signal()
    try await first
    do {
      try await poisoned
      Issue.record("duplicate create must throw")
    } catch {
      #expect(error as? DBError == DBError.tableExists("documents"))
    }
    try await second
    _ = await blockerTask.value

    let schema = try db.read { (txn) throws(DBError) in try txn.schema() }
    #expect(Set(schema.tables.keys) == ["documents", "ok_table"])
    #expect(schema.indexes["ok_idx"] != nil)
    #expect(schema.tables["ghost_table"] == nil, "rolled-back DDL leaked")
    _ = try db.verifyIntegrity()
  }
}

@Suite("Relation DDL crash atomicity")
struct RelationDDLCrashTests {
  @Test func ddlCrashSweepIsAllOrNothing() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let disk = try SimulatedDisk(path: dir.file("ddl-sweep.adsql"))
    defer { disk.close() }

    var meta = try Recovery.openOrCreate(channel: disk)
    let pager = try Pager(channel: disk, maxMapSize: 1 << 30)
    var tablesByGeneration: [UInt64: Set<String>] = [0: []]

    // Production lifecycle per txn: harvest → DDL → serializeState →
    // FreeList.serialize → commit.
    var expected: Set<String> = []
    for round in 0..<6 {
      let ctx = TxnContext(source: pager, meta: meta)
      try FreeList.harvest(ctx: ctx, upTo: meta.reclaimLimit(minReader: .max))
      let name = "table_\(round)"
      try Relation.createTable(ctx, documentsTable(name))
      try Relation.createIndex(
        ctx, IndexDefinition("idx_\(round)", on: name, columns: ["key"], unique: round % 2 == 0))
      if round == 3 {
        try Relation.dropTable(ctx, name: "table_1")
        expected.remove("table_1")
      }
      expected.insert(name)
      try Relation.serializeState(ctx: ctx)
      try FreeList.serialize(ctx: ctx)
      meta = try Committer.commit(ctx: ctx, channel: disk, durability: .barrier)
      tablesByGeneration[meta.generation] = expected
    }

    for cutGroup in disk.crashCutGroups {
      for tearSeed: UInt64 in 0..<4 {
        let image = disk.materializeCrashImage(cutGroup: cutGroup, tearSeed: tearSeed)
        let path = dir.file("cut-\(cutGroup)-\(tearSeed).adsql")
        try disk.writeCrashImage(image, to: path)
        let channel = try FileChannel(path: path, mode: .readWrite(create: false))
        defer { channel.close() }
        let recovered = try Recovery.openOrCreate(channel: channel, createIfMissing: false)
        guard let want = tablesByGeneration[recovered.generation] else {
          Issue.record("recovered unknown generation \(recovered.generation)")
          continue
        }
        let cutPager = try Pager(channel: channel, maxMapSize: 1 << 30)
        let resolver = CommittedResolver(source: cutPager)
        let state = try Relation.loadState(resolver: resolver, mainTree: recovered.mainTree)
        #expect(
          Set(state.tableRecords.keys) == want,
          "generation \(recovered.generation): tables \(state.tableRecords.keys.sorted())")
        // Each table has exactly its index; whole-file liveness holds and
        // every index entry bijects to its row.
        _ = try Integrity.check(resolver: resolver, meta: recovered, deep: true)
      }
    }
  }
}

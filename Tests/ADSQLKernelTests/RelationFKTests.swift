import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

@Suite("Relation foreign keys")
struct RelationFKTests {
  /// documents → sections → chunks, the apple-docs cascade shape.
  func makeChainDB(_ dir: TempDir, sectionsAction: FKAction = .cascade) throws -> Database {
    let db = try Database.open(at: dir.file("fk.adsql"))
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(TableDefinition(
        "documents",
        columns: [
          ColumnDefinition("id", .integer, notNull: true),
          ColumnDefinition("key", .text, notNull: true),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true)))
      try txn.createTable(TableDefinition(
        "sections",
        columns: [
          ColumnDefinition("id", .integer, notNull: true),
          ColumnDefinition("document_id", .integer, notNull: true),
          ColumnDefinition("heading", .text),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true),
        foreignKeys: [
          ForeignKey(childColumns: ["document_id"], parentTable: "documents", onDelete: sectionsAction)
        ]))
      try txn.createTable(TableDefinition(
        "chunks",
        columns: [
          ColumnDefinition("section_id", .integer, notNull: true),
          ColumnDefinition("ord", .integer, notNull: true),
        ],
        foreignKeys: [
          ForeignKey(childColumns: ["section_id"], parentTable: "sections", onDelete: .cascade)
        ]))
      try txn.createIndex(IndexDefinition("i_sections_doc", on: "sections", columns: ["document_id"]))
      try txn.createIndex(IndexDefinition("i_chunks_section", on: "chunks", columns: ["section_id"]))
    }
    return db
  }

  @Test func twoLevelCascade() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try makeChainDB(dir)
    defer { db.close() }

    try db.writeSync { (txn) throws(DBError) in
      for d in 0..<3 {
        let doc = try txn.insert(into: "documents", ["key": .text("doc-\(d)")])!
        for s in 0..<4 {
          let section = try txn.insert(into: "sections", [
            "document_id": .integer(doc), "heading": .text("h\(s)"),
          ])!
          for o in 0..<5 {
            _ = try txn.insert(into: "chunks", [
              "section_id": .integer(section), "ord": .integer(Int64(o)),
            ])
          }
        }
      }
    }
    let before = try db.read { (txn) throws(DBError) in
      (docs: try txn.rowCount(in: "documents"),
       sections: try txn.rowCount(in: "sections"),
       chunks: try txn.rowCount(in: "chunks"))
    }
    #expect(before == (3, 12, 60))

    // Deleting one document removes its 4 sections and their 20 chunks.
    try db.writeSync { (txn) throws(DBError) in
      let existed = try txn.delete(from: "documents", rowid: 2)
      guard existed else { throw DBError.integrityFailure("doc 2 missing") }
    }
    let after = try db.read { (txn) throws(DBError) in
      (docs: try txn.rowCount(in: "documents"),
       sections: try txn.rowCount(in: "sections"),
       chunks: try txn.rowCount(in: "chunks"))
    }
    #expect(after == (2, 8, 40))
    _ = try db.verifyIntegrity(deep: true)
  }

  @Test func restrictBlocksDelete() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try makeChainDB(dir, sectionsAction: .restrict)
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      let doc = try txn.insert(into: "documents", ["key": .text("locked")])!
      _ = try txn.insert(into: "sections", ["document_id": .integer(doc)])
    }
    #expect(throws: DBError.foreignKeyViolation(table: "sections")) {
      try db.writeSync { (txn) throws(DBError) in
        _ = try txn.delete(from: "documents", rowid: 1)
      }
    }
    // Nothing was deleted; childless documents still deletable.
    let counts = try db.read { (txn) throws(DBError) in
      (try txn.rowCount(in: "documents"), try txn.rowCount(in: "sections"))
    }
    #expect(counts == (1, 1))
    try db.writeSync { (txn) throws(DBError) in
      _ = try txn.delete(from: "sections", rowid: 1)
      _ = try txn.delete(from: "documents", rowid: 1)
    }
    #expect(try db.read { (txn) throws(DBError) in try txn.rowCount(in: "documents") } == 0)
    _ = try db.verifyIntegrity(deep: true)
  }

  @Test func cascadeWithoutChildIndexIsTypedError() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("noidx.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(TableDefinition(
        "p", columns: [ColumnDefinition("id", .integer)],
        primaryKey: .rowidAlias(column: "id", autoincrement: false)))
      try txn.createTable(TableDefinition(
        "c", columns: [ColumnDefinition("p_id", .integer)],
        foreignKeys: [ForeignKey(childColumns: ["p_id"], parentTable: "p", onDelete: .cascade)]))
      _ = try txn.insert(into: "p", [:])
    }
    #expect(throws: DBError.self) {
      try db.writeSync { (txn) throws(DBError) in
        _ = try txn.delete(from: "p", rowid: 1)
      }
    }
    // Adding the index unblocks the delete.
    try db.writeSync { (txn) throws(DBError) in
      try txn.createIndex(IndexDefinition("i_c_p", on: "c", columns: ["p_id"]))
    }
    try db.writeSync { (txn) throws(DBError) in
      _ = try txn.delete(from: "p", rowid: 1)
    }
    _ = try db.verifyIntegrity(deep: true)
  }

  @Test func replaceTriggersCascade() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("repl.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(TableDefinition(
        "docs",
        columns: [
          ColumnDefinition("id", .integer, notNull: true),
          ColumnDefinition("key", .text, notNull: true),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true)))
      try txn.createIndex(IndexDefinition("u_key", on: "docs", columns: ["key"], unique: true))
      try txn.createTable(TableDefinition(
        "notes", columns: [ColumnDefinition("doc_id", .integer)],
        foreignKeys: [ForeignKey(childColumns: ["doc_id"], parentTable: "docs", onDelete: .cascade)]))
      try txn.createIndex(IndexDefinition("i_notes_doc", on: "notes", columns: ["doc_id"]))
      let doc = try txn.insert(into: "docs", ["key": .text("k")])!
      _ = try txn.insert(into: "notes", ["doc_id": .integer(doc)])
    }
    // REPLACE deletes the conflicting doc → its notes cascade away.
    try db.writeSync { (txn) throws(DBError) in
      _ = try txn.insert(into: "docs", ["key": .text("k")], onConflict: .replace)
    }
    let counts = try db.read { (txn) throws(DBError) in
      (try txn.rowCount(in: "docs"), try txn.rowCount(in: "notes"))
    }
    #expect(counts == (1, 0))
    _ = try db.verifyIntegrity(deep: true)
  }

  @Test func selfReferenceTerminates() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("self.adsql"))
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      try txn.createTable(TableDefinition(
        "categories",
        columns: [
          ColumnDefinition("id", .integer, notNull: true),
          ColumnDefinition("parent_id", .integer),
        ],
        primaryKey: .rowidAlias(column: "id", autoincrement: true),
        foreignKeys: [
          ForeignKey(childColumns: ["parent_id"], parentTable: "categories", onDelete: .cascade)
        ]))
      try txn.createIndex(IndexDefinition("i_cat_parent", on: "categories", columns: ["parent_id"]))
      // root(1) → a(2), b(3); a → leaf(4)
      let root = try txn.insert(into: "categories", ["parent_id": .null])!
      let a = try txn.insert(into: "categories", ["parent_id": .integer(root)])!
      _ = try txn.insert(into: "categories", ["parent_id": .integer(root)])
      _ = try txn.insert(into: "categories", ["parent_id": .integer(a)])
    }
    try db.writeSync { (txn) throws(DBError) in
      _ = try txn.delete(from: "categories", rowid: 1)
    }
    #expect(try db.read { (txn) throws(DBError) in try txn.rowCount(in: "categories") } == 0)
    _ = try db.verifyIntegrity(deep: true)
  }
}

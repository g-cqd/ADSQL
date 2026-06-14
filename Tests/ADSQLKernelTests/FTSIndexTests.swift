import ADSQLTestSupport
import Testing

@testable import ADSQLKernel

/// M5 / F2b — self-contained FTS index build + maintenance through the SQL write
/// API. Inspection uses the internal read helpers (the SQL MATCH query is F3).
@Suite("FTS5 — F2b index build + maintenance")
struct FTSIndexTests {
    private func run(_ db: Database, _ sql: String) throws { try db.prepare(sql).run() }

    /// `term` after porter stemming, as bytes.
    private func term(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func makeDocsTable(_ db: Database) throws {
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='porter unicode61')")
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(10, 'Swift Running', 'the cats are running fast')")
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(20, 'Python', 'snakes slither')")
        try run(db, "INSERT INTO fts(rowid, title, body) VALUES(30, 'Running shoes', 'fast running')")
    }

    @Test func buildsPostingsDfAndStats() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("fts.adsql"))
        defer { db.close() }
        try makeDocsTable(db)

        try db.writeSync { (txn) throws(DBError) in
            // "running"/"Running" stem to "run": docs 10 and 30, in docid order.
            let run = try txn.ftsPostings("fts", term: term("run"))
            #expect(run?.map(\.docid) == [10, 30])
            #expect(run?[0].fieldTFs == [1, 1])  // title + body each once in doc 10
            #expect(try txn.ftsDocumentFrequency("fts", term: term("run")) == 2)

            // "swift" only in doc 10's title.
            #expect(try txn.ftsPostings("fts", term: term("swift"))?.map(\.docid) == [10])

            let global = try txn.ftsGlobalStats("fts")
            #expect(global.docCount == 3)
            // doc 10 lengths: title "Swift Running" = 2 tokens, body = 5 tokens.
            #expect(try txn.ftsDocStats("fts", docid: 10)?.fieldLengths == [2, 5])
        }
    }

    /// F6f memtable read-your-writes: docs added in a transaction are buffered, but
    /// a MATCH in the SAME transaction flushes the buffer first and sees them; a
    /// further add after a read re-buffers and is visible to the next read; and the
    /// whole batch is durable after commit.
    @Test func memtableFlushesBeforeSameTransactionRead() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("ftsryw.adsql")
        do {
            let db = try Database.open(at: path)
            defer { db.close() }
            try run(db, "CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='porter unicode61')")
            try db.writeSync { (txn) throws(DBError) in
                try txn.ftsAdd("fts", docid: 1, columnTexts: ["swift structured concurrency"])
                try txn.ftsAdd("fts", docid: 2, columnTexts: ["python static typing"])
                // Same-transaction MATCH must flush the buffer first and see the docs.
                #expect(try txn.ftsMatch("fts", "swift") == [1])
                #expect(try txn.ftsMatch("fts", "python") == [2])
                // A further add after a read re-buffers and is seen by the next read.
                try txn.ftsAdd("fts", docid: 3, columnTexts: ["swift on the server"])
                #expect(try txn.ftsMatch("fts", "swift") == [1, 3])
            }
        }
        // Reopen: the batch is durable.
        let db = try Database.open(at: path)
        defer { db.close() }
        let hits = try db.prepare("SELECT rowid FROM fts WHERE fts MATCH 'swift' ORDER BY rowid")
            .all().map { row -> Int64 in
                guard case .integer(let id) = row[0] else { return -1 }
                return id
            }
        #expect(hits == [1, 3])
    }

    /// F6f: batches that span the 128-doc block boundary stay complete and packed —
    /// `writePacked` for a new term across two blocks, then the ascending-append
    /// path re-packing the last partial block plus new blocks for a follow-on batch.
    @Test func memtableBatchSpansBlockBoundaries() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftsbatch.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='porter unicode61')")
        // Phase 1: 200 docs of one term in one transaction → new term, two 128 blocks.
        try db.writeSync { (txn) throws(DBError) in
            for id in 1...200 { try txn.ftsAdd("fts", docid: Int64(id), columnTexts: ["common"]) }
        }
        // Phase 2: 100 more in another transaction → ascending-append path across the
        // partial last block and into new blocks.
        try db.writeSync { (txn) throws(DBError) in
            for id in 201...300 { try txn.ftsAdd("fts", docid: Int64(id), columnTexts: ["common"]) }
        }
        try db.writeSync { (txn) throws(DBError) in
            let postings = try txn.ftsPostings("fts", term: term("common"))
            #expect(postings?.count == 300)
            #expect(postings?.map(\.docid) == (1...300).map(Int64.init))
            #expect(try txn.ftsDocumentFrequency("fts", term: term("common")) == 300)
        }
    }

    @Test func deleteUpdatesIndexAndPersists() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("ftsdel.adsql")
        do {
            let db = try Database.open(at: path)
            defer { db.close() }
            try makeDocsTable(db)
            try run(db, "DELETE FROM fts WHERE rowid = 10")

            try db.writeSync { (txn) throws(DBError) in
                #expect(try txn.ftsPostings("fts", term: term("run"))?.map(\.docid) == [30])
                #expect(try txn.ftsDocumentFrequency("fts", term: term("run")) == 1)
                // "swift" was unique to doc 10 → term gone entirely.
                #expect(try txn.ftsPostings("fts", term: term("swift")) == nil)
                #expect(try txn.ftsGlobalStats("fts").docCount == 2)
                #expect(try txn.ftsDocStats("fts", docid: 10) == nil)
            }
        }
        // Reopen: the index survives.
        let reopened = try Database.open(at: path)
        defer { reopened.close() }
        try reopened.writeSync { (txn) throws(DBError) in
            #expect(try txn.ftsPostings("fts", term: term("run"))?.map(\.docid) == [30])
            #expect(try txn.ftsGlobalStats("fts").docCount == 2)
        }
    }

    @Test func autoRowidIncrements() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftsauto.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(body)")
        try run(db, "INSERT INTO fts(body) VALUES('alpha')")
        try run(db, "INSERT INTO fts(body) VALUES('beta')")
        try run(db, "INSERT INTO fts(body) VALUES('gamma')")
        try db.writeSync { (txn) throws(DBError) in
            #expect(try txn.ftsPostings("fts", term: term("alpha"))?.map(\.docid) == [1])
            #expect(try txn.ftsPostings("fts", term: term("beta"))?.map(\.docid) == [2])
            #expect(try txn.ftsPostings("fts", term: term("gamma"))?.map(\.docid) == [3])
        }
    }

    @Test func rejectsDuplicateDocidAndUnsupportedShapes() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftsrej.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(title)")
        try run(db, "INSERT INTO fts(rowid, title) VALUES(5, 'x')")
        #expect(throws: DBError.self) { try run(db, "INSERT INTO fts(rowid, title) VALUES(5, 'y')") }
        // DELETE must be by rowid; a column predicate is unsupported.
        #expect(throws: DBError.self) { try run(db, "DELETE FROM fts WHERE title = 'x'") }
        // RETURNING on an FTS table is rejected.
        #expect(throws: DBError.self) {
            try run(db, "INSERT INTO fts(rowid, title) VALUES(6, 'z') RETURNING rowid")
        }
    }

    // MARK: F2c — content modes + the 'delete' idiom

    @Test func externalContentSyncsViaDeleteIdiom() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("ftsext.adsql")
        do {
            let db = try Database.open(at: path)
            defer { db.close() }
            try run(db, "CREATE VIRTUAL TABLE ft USING fts5(title, content='documents', content_rowid='id')")
            try run(db, "INSERT INTO ft(rowid, title) VALUES(1, 'alpha beta')")
            try run(db, "INSERT INTO ft(rowid, title) VALUES(2, 'beta gamma')")
            try db.writeSync { (txn) throws(DBError) in
                #expect(try txn.ftsPostings("ft", term: term("beta"))?.map(\.docid) == [1, 2])
                #expect(try txn.ftsGlobalStats("ft").docCount == 2)
            }
            // How the AFTER DELETE trigger will sync: the 'delete' command idiom.
            try run(db, "INSERT INTO ft(ft, rowid, title) VALUES('delete', 1, 'alpha beta')")
            try db.writeSync { (txn) throws(DBError) in
                #expect(try txn.ftsPostings("ft", term: term("beta"))?.map(\.docid) == [2])
                #expect(try txn.ftsPostings("ft", term: term("alpha")) == nil)
                #expect(try txn.ftsGlobalStats("ft").docCount == 1)
            }
        }
        let reopened = try Database.open(at: path)
        defer { reopened.close() }
        try reopened.writeSync { (txn) throws(DBError) in
            #expect(try txn.ftsPostings("ft", term: term("beta"))?.map(\.docid) == [2])
        }
    }

    @Test func contentlessSyncsViaDeleteIdiom() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftscl.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE ft USING fts5(body, content='', contentless_delete=1)")
        try run(db, "INSERT INTO ft(rowid, body) VALUES(1, 'hello world')")
        try run(db, "INSERT INTO ft(rowid, body) VALUES(2, 'world peace')")
        try run(db, "INSERT INTO ft(ft, rowid, body) VALUES('delete', 1, 'hello world')")
        try db.writeSync { (txn) throws(DBError) in
            #expect(try txn.ftsPostings("ft", term: term("world"))?.map(\.docid) == [2])
            #expect(try txn.ftsPostings("ft", term: term("hello")) == nil)
            #expect(try txn.ftsGlobalStats("ft").docCount == 1)
        }
    }

    @Test func deleteAllClearsIndex() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("ftsall.adsql")
        do {
            let db = try Database.open(at: path)
            defer { db.close() }
            try run(db, "CREATE VIRTUAL TABLE fts USING fts5(body)")
            try run(db, "INSERT INTO fts(rowid, body) VALUES(1, 'alpha')")
            try run(db, "INSERT INTO fts(rowid, body) VALUES(2, 'beta')")
            try run(db, "INSERT INTO fts(fts) VALUES('delete-all')")
            try db.writeSync { (txn) throws(DBError) in
                #expect(try txn.ftsPostings("fts", term: term("alpha")) == nil)
                #expect(try txn.ftsGlobalStats("fts").docCount == 0)
            }
            // The table is reusable after a clear.
            try run(db, "INSERT INTO fts(rowid, body) VALUES(3, 'gamma')")
        }
        let reopened = try Database.open(at: path)
        defer { reopened.close() }
        try reopened.writeSync { (txn) throws(DBError) in
            #expect(try txn.ftsPostings("fts", term: term("gamma"))?.map(\.docid) == [3])
            #expect(try txn.ftsPostings("fts", term: term("alpha")) == nil)
        }
    }

    @Test func idiomDeleteMatchesPlainDeleteAndRejectsUnknownCommand() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("ftscmd.adsql"))
        defer { db.close() }
        try run(db, "CREATE VIRTUAL TABLE fts USING fts5(title, tokenize='porter unicode61')")
        try run(db, "INSERT INTO fts(rowid, title) VALUES(1, 'running')")
        try run(db, "INSERT INTO fts(rowid, title) VALUES(2, 'running')")
        #expect(throws: DBError.self) { try run(db, "INSERT INTO fts(fts, rowid) VALUES('rebuild', 1)") }
        // Idiom delete (doc 1) and plain delete (doc 2) leave the index empty.
        try run(db, "INSERT INTO fts(fts, rowid, title) VALUES('delete', 1, 'running')")
        try run(db, "DELETE FROM fts WHERE rowid = 2")
        try db.writeSync { (txn) throws(DBError) in
            #expect(try txn.ftsPostings("fts", term: term("run")) == nil)
            #expect(try txn.ftsGlobalStats("fts").docCount == 0)
        }
    }
}

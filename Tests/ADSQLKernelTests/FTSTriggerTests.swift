import ADSQLTestSupport
import CSQLite
import Testing

@testable import ADSQLKernel

/// M5 / F5 — general `CREATE TRIGGER`. AFTER INSERT/UPDATE/DELETE row triggers
/// whose body is INSERT/DELETE/UPDATE statements referencing `NEW.*`/`OLD.*`,
/// fired inside the same write transaction. The headline consumer is apple-docs's
/// FTS-sync DDL (the ai/ad/au triggers keeping `documents_fts` in step with
/// `documents`); this suite covers parsing, catalog persistence (re-parsed on
/// reopen), end-to-end FTS sync, plain (non-FTS) firing with a CSQLite
/// differential, DROP, IF [NOT] EXISTS, and the recursion-depth guard.
@Suite("FTS5 — F5 general CREATE TRIGGER")
struct FTSTriggerTests {
    private func parse(_ sql: String) throws -> SQLStatementAST {
        try SQLParser.parseOne(sql)
    }

    // The three apple-docs FTS-sync triggers, verbatim.
    private static let aiTrigger = """
        CREATE TRIGGER documents_ai AFTER INSERT ON documents BEGIN
          INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key)
          VALUES (new.id, new.title, new.abstract, new.declaration, new.headings, new.key);
        END
        """
    private static let adTrigger = """
        CREATE TRIGGER documents_ad AFTER DELETE ON documents BEGIN
          INSERT INTO documents_fts(documents_fts, rowid, title, abstract, declaration, headings, key)
          VALUES('delete', old.id, old.title, old.abstract, old.declaration, old.headings, old.key);
        END
        """
    private static let auTrigger = """
        CREATE TRIGGER documents_au AFTER UPDATE ON documents BEGIN
          INSERT INTO documents_fts(documents_fts, rowid, title, abstract, declaration, headings, key)
          VALUES('delete', old.id, old.title, old.abstract, old.declaration, old.headings, old.key);
          INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key)
          VALUES (new.id, new.title, new.abstract, new.declaration, new.headings, new.key);
        END
        """

    // MARK: - Parsing

    @Test func parsesTheThreeAppleDocsTriggers() throws {
        guard case .createTrigger(let ai) = try parse(Self.aiTrigger) else {
            Issue.record("ai not createTrigger")
            return
        }
        #expect(ai.definition.name == "documents_ai")
        #expect(ai.definition.table == "documents")
        #expect(ai.definition.event == .insert)
        #expect(ai.definition.whenExpr == nil)
        #expect(ai.definition.body.count == 1)
        if case .insert(let insert) = ai.definition.body[0] {
            #expect(insert.table == "documents_fts")
        } else {
            Issue.record("ai body is not an INSERT")
        }

        guard case .createTrigger(let ad) = try parse(Self.adTrigger) else {
            Issue.record("ad not createTrigger")
            return
        }
        #expect(ad.definition.event == .delete)
        #expect(ad.definition.body.count == 1)

        guard case .createTrigger(let au) = try parse(Self.auTrigger) else {
            Issue.record("au not createTrigger")
            return
        }
        #expect(au.definition.event == .update)
        #expect(au.definition.body.count == 2)  // delete idiom + re-insert
    }

    @Test func parsesForEachRowAndWhenAndIfNotExists() throws {
        guard
            case .createTrigger(let t) = try parse(
                """
                CREATE TRIGGER IF NOT EXISTS audit_ins AFTER INSERT ON items FOR EACH ROW
                WHEN new.qty > 0 BEGIN
                  INSERT INTO audit(item, qty) VALUES(new.id, new.qty);
                END
                """)
        else {
            Issue.record("not createTrigger")
            return
        }
        #expect(t.ifNotExists)
        #expect(t.definition.event == .insert)
        #expect(t.definition.whenExpr != nil)
        #expect(t.definition.body.count == 1)
    }

    @Test func dropTriggerParses() throws {
        guard case .dropTrigger(let name, let ifExists) = try parse("DROP TRIGGER documents_ai") else {
            Issue.record("not dropTrigger")
            return
        }
        #expect(name == "documents_ai")
        #expect(ifExists == false)
        guard case .dropTrigger(_, let ifExists2) = try parse("DROP TRIGGER IF EXISTS x") else {
            Issue.record("not dropTrigger")
            return
        }
        #expect(ifExists2)
    }

    @Test func beforeTriggerIsUnsupported() throws {
        #expect(throws: DBError.sqlUnsupported("BEFORE triggers")) {
            _ = try parse("CREATE TRIGGER t BEFORE INSERT ON x BEGIN DELETE FROM y; END")
        }
        #expect(throws: DBError.sqlUnsupported("INSTEAD OF triggers")) {
            _ = try parse("CREATE TRIGGER t INSTEAD OF INSERT ON x BEGIN DELETE FROM y; END")
        }
    }

    @Test func nonMutatingTriggerBodyRejected() throws {
        // A trigger body queries nothing and defines nothing.
        #expect(throws: DBError.self) {
            _ = try parse("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END")
        }
        #expect(throws: DBError.self) {
            _ = try parse("CREATE TRIGGER t AFTER INSERT ON x BEGIN; END")  // empty body
        }
    }

    @Test func triggerKeywordsStillUsableAsIdentifiers() throws {
        // AFTER/BEFORE/ROW/OF/FOR/EACH/INSTEAD are non-reserved: still column names.
        guard
            case .createTable(let create) = try parse(
                "CREATE TABLE t(row INTEGER, after TEXT, of TEXT)")
        else {
            Issue.record("not createTable")
            return
        }
        #expect(create.definition.columns.map(\.name) == ["row", "after", "of"])
    }

    // MARK: - Catalog persistence (store + survive reopen)

    @Test func triggersPersistAndReparseOnReopen() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("triggers.adsql")

        do {
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.prepare(
                """
                CREATE TABLE documents(
                  id INTEGER PRIMARY KEY, title TEXT, abstract TEXT, declaration TEXT,
                  headings TEXT, key TEXT)
                """
            ).run()
            try db.prepare(
                """
                CREATE VIRTUAL TABLE documents_fts USING fts5(
                  title, abstract, declaration, headings, key, tokenize='porter unicode61')
                """
            ).run()
            try db.prepare(Self.aiTrigger).run()
            try db.prepare(Self.adTrigger).run()
            try db.prepare(Self.auTrigger).run()

            let names = try db.writeSync { (txn) throws(DBError) in
                try txn.schema().triggers.keys.sorted()
            }
            #expect(names == ["documents_ad", "documents_ai", "documents_au"])
        }

        // Reopen: triggers re-parse from the stored CREATE TRIGGER text.
        do {
            let db = try Database.open(at: path)
            defer { db.close() }
            let triggers = try db.writeSync { (txn) throws(DBError) -> [String: TriggerDefinition] in
                try txn.schema().triggers
            }
            #expect(triggers.count == 3)
            #expect(triggers["documents_ai"]?.event == .insert)
            #expect(triggers["documents_ad"]?.event == .delete)
            #expect(triggers["documents_au"]?.event == .update)
            #expect(triggers["documents_au"]?.body.count == 2)
            #expect(triggers["documents_ai"]?.table == "documents")
            _ = try db.verifyIntegrity(deep: true)
        }
    }

    @Test func nameClashAndMissingTableRules() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("clash.adsql"))
        defer { db.close() }
        try db.prepare("CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT)").run()
        try db.prepare("CREATE VIRTUAL TABLE documents_fts USING fts5(title)").run()
        try db.prepare(
            "CREATE TRIGGER t1 AFTER INSERT ON documents BEGIN DELETE FROM documents WHERE id < 0; END"
        ).run()

        // Duplicate trigger name.
        #expect(throws: DBError.triggerExists("t1")) {
            try db.prepare(
                "CREATE TRIGGER t1 AFTER DELETE ON documents BEGIN DELETE FROM documents WHERE id < 0; END"
            ).run()
        }
        // IF NOT EXISTS makes the redefinition a no-op.
        try db.prepare(
            "CREATE TRIGGER IF NOT EXISTS t1 AFTER DELETE ON documents BEGIN DELETE FROM documents WHERE id<0; END"
        ).run()
        // Trigger on a missing table.
        #expect(throws: DBError.noSuchTable("ghost")) {
            try db.prepare("CREATE TRIGGER t2 AFTER INSERT ON ghost BEGIN DELETE FROM documents; END").run()
        }
        // Trigger on a virtual table is rejected.
        #expect(throws: DBError.self) {
            try db.prepare(
                "CREATE TRIGGER t3 AFTER INSERT ON documents_fts BEGIN DELETE FROM documents; END"
            ).run()
        }
        // DROP semantics.
        #expect(throws: DBError.noSuchTrigger("missing")) {
            try db.prepare("DROP TRIGGER missing").run()
        }
        try db.prepare("DROP TRIGGER IF EXISTS missing").run()  // no-op
        try db.prepare("DROP TRIGGER t1").run()
        let gone = try db.writeSync { (txn) throws(DBError) in try txn.schema().triggers["t1"] }
        #expect(gone == nil)
    }

    @Test func dropTableDropsItsTriggers() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("droptbl.adsql"))
        defer { db.close() }
        try db.prepare("CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT)").run()
        try db.prepare("CREATE TABLE audit(id INTEGER PRIMARY KEY, item INTEGER)").run()
        try db.prepare(
            "CREATE TRIGGER t AFTER INSERT ON documents BEGIN INSERT INTO audit(item) VALUES(new.id); END"
        ).run()
        #expect(try db.writeSync { (txn) throws(DBError) in try txn.schema().triggers.count } == 1)
        try db.prepare("DROP TABLE documents").run()
        #expect(try db.writeSync { (txn) throws(DBError) in try txn.schema().triggers.count } == 0)
    }

    // MARK: - End-to-end FTS sync (the apple-docs shape)

    /// Builds `documents` + `documents_fts` + the ai/ad/au triggers, then drives
    /// the FTS index entirely through base-table DML, asserting via the MATCH SQL
    /// surface that the triggers keep the index in step.
    private func ftsSyncFixture(_ dir: TempDir) throws -> Database {
        let db = try Database.open(at: dir.file("ftssync.adsql"))
        try db.prepare(
            """
            CREATE TABLE documents(
              id INTEGER PRIMARY KEY, title TEXT, abstract TEXT, declaration TEXT,
              headings TEXT, key TEXT)
            """
        ).run()
        try db.prepare(
            """
            CREATE VIRTUAL TABLE documents_fts USING fts5(
              title, abstract, declaration, headings, key, tokenize='porter unicode61')
            """
        ).run()
        try db.prepare(Self.aiTrigger).run()
        try db.prepare(Self.adTrigger).run()
        try db.prepare(Self.auTrigger).run()
        return db
    }

    private func matchIds(_ db: Database, _ query: String) throws -> [Int64] {
        try db.prepare(
            "SELECT rowid FROM documents_fts WHERE documents_fts MATCH ? ORDER BY rowid"
        ).all(.text(query)).map { row in
            guard case .integer(let id) = row[0] else { return Int64(-1) }
            return id
        }
    }

    @Test func insertTriggerSyncsFTS() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try ftsSyncFixture(dir)
        defer { db.close() }
        // A plain base-table INSERT (no direct FTS write): the AI trigger indexes it.
        try db.prepare(
            """
            INSERT INTO documents(id, title, abstract, declaration, headings, key)
            VALUES(1, 'swift concurrency', 'async await tasks', 'func run()', 'Overview', 'doc/swift')
            """
        ).run()
        try db.prepare(
            """
            INSERT INTO documents(id, title, abstract, declaration, headings, key)
            VALUES(2, 'python guide', 'beginner tutorial', 'def main()', 'Intro', 'doc/python')
            """
        ).run()
        #expect(try matchIds(db, "swift") == [1])
        #expect(try matchIds(db, "tasks") == [1])
        #expect(try matchIds(db, "tutorial") == [2])
        #expect(try matchIds(db, "guide") == [2])
        #expect(try matchIds(db, "nonexistent").isEmpty)
    }

    @Test func updateTriggerResyncsFTS() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try ftsSyncFixture(dir)
        defer { db.close() }
        try db.prepare(
            """
            INSERT INTO documents(id, title, abstract, declaration, headings, key)
            VALUES(1, 'swift intro', 'old body text', '', '', 'k1')
            """
        ).run()
        #expect(try matchIds(db, "swift") == [1])
        #expect(try matchIds(db, "old") == [1])

        // UPDATE fires AU: the 'delete' idiom removes the stale doc, then re-inserts.
        try db.prepare("UPDATE documents SET title = ?, abstract = ? WHERE id = 1").run(
            .text("rust systems"), .text("new body text"))
        #expect(try matchIds(db, "swift").isEmpty, "stale term must be gone after UPDATE")
        #expect(try matchIds(db, "old").isEmpty)
        #expect(try matchIds(db, "rust") == [1])
        #expect(try matchIds(db, "new") == [1])
    }

    @Test func deleteTriggerRemovesFromFTS() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try ftsSyncFixture(dir)
        defer { db.close() }
        try db.prepare(
            """
            INSERT INTO documents(id, title, abstract, declaration, headings, key)
            VALUES(1, 'swift intro', 'body one', '', '', 'k1')
            """
        ).run()
        try db.prepare(
            """
            INSERT INTO documents(id, title, abstract, declaration, headings, key)
            VALUES(2, 'swift advanced', 'body two', '', '', 'k2')
            """
        ).run()
        #expect(try matchIds(db, "swift") == [1, 2])

        // DELETE fires AD (the 'delete' idiom), removing doc 1 from the index.
        try db.prepare("DELETE FROM documents WHERE id = 1").run()
        #expect(try matchIds(db, "swift") == [2])
        #expect(try matchIds(db, "one").isEmpty)
        #expect(try matchIds(db, "two") == [2])
    }

    @Test func fullSyncSurvivesReopen() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("ftssync-reopen.adsql")
        do {
            let db = try Database.open(at: path)
            defer { db.close() }
            try db.prepare(
                """
                CREATE TABLE documents(
                  id INTEGER PRIMARY KEY, title TEXT, abstract TEXT, declaration TEXT,
                  headings TEXT, key TEXT)
                """
            ).run()
            try db.prepare(
                """
                CREATE VIRTUAL TABLE documents_fts USING fts5(
                  title, abstract, declaration, headings, key, tokenize='porter unicode61')
                """
            ).run()
            try db.prepare(Self.aiTrigger).run()
            try db.prepare(
                """
                INSERT INTO documents(id, title, abstract, declaration, headings, key)
                VALUES(7, 'metal shaders', 'gpu kernels', '', '', 'k7')
                """
            ).run()
        }
        // Reopen: the trigger re-parses from the catalog and still fires.
        do {
            let db = try Database.open(at: path)
            defer { db.close() }
            #expect(try matchIds(db, "metal") == [7])
            try db.prepare(
                """
                INSERT INTO documents(id, title, abstract, declaration, headings, key)
                VALUES(8, 'metal compute', 'threadgroups', '', '', 'k8')
                """
            ).run()
            #expect(try matchIds(db, "metal") == [7, 8])
            _ = try db.verifyIntegrity(deep: true)
        }
    }

    // MARK: - Plain (non-FTS) trigger + CSQLite differential

    /// An audit-log trigger writing NEW/OLD values to a second table. Asserts the
    /// resulting rows match real SQLite running the identical DDL/DML.
    @Test func plainAuditTriggerMatchesSQLite() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("audit.adsql"))
        defer { db.close() }

        let ddl = [
            "CREATE TABLE accounts(id INTEGER PRIMARY KEY, name TEXT, balance INTEGER)",
            "CREATE TABLE audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, acct INTEGER, old_bal INTEGER, new_bal INTEGER)",
            """
            CREATE TRIGGER acct_ai AFTER INSERT ON accounts BEGIN
              INSERT INTO audit(kind, acct, old_bal, new_bal) VALUES('insert', new.id, NULL, new.balance);
            END
            """,
            """
            CREATE TRIGGER acct_au AFTER UPDATE ON accounts BEGIN
              INSERT INTO audit(kind, acct, old_bal, new_bal) VALUES('update', new.id, old.balance, new.balance);
            END
            """,
            """
            CREATE TRIGGER acct_ad AFTER DELETE ON accounts BEGIN
              INSERT INTO audit(kind, acct, old_bal, new_bal) VALUES('delete', old.id, old.balance, NULL);
            END
            """,
        ]
        let dml = [
            "INSERT INTO accounts(id, name, balance) VALUES(1, 'alice', 100)",
            "INSERT INTO accounts(id, name, balance) VALUES(2, 'bob', 50)",
            "UPDATE accounts SET balance = 175 WHERE id = 1",
            "UPDATE accounts SET balance = balance - 10 WHERE id = 2",
            "DELETE FROM accounts WHERE id = 1",
        ]
        for sql in ddl + dml { try db.prepare(sql).run() }

        let auditQuery = "SELECT kind, acct, old_bal, new_bal FROM audit ORDER BY seq"
        let ours = try db.prepare(auditQuery).all().map(\.values)

        let mirror = SQLiteMirror()
        for sql in ddl + dml { try mirror.exec(sql) }
        let theirs = try mirror.query(auditQuery)

        #expect(rowsMatch(ours, theirs, ordered: true), "adsql \(ours)\nsqlite \(theirs)")
        // Spot-check the captured NEW/OLD values directly too.
        let expected: [[Value]] = [
            [.text("insert"), .integer(1), .null, .integer(100)],
            [.text("insert"), .integer(2), .null, .integer(50)],
            [.text("update"), .integer(1), .integer(100), .integer(175)],
            [.text("update"), .integer(2), .integer(50), .integer(40)],
            [.text("delete"), .integer(1), .integer(175), .null],
        ]
        #expect(ours == expected)
    }

    @Test func whenClauseGatesFiring() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("when.adsql"))
        defer { db.close() }
        try db.prepare("CREATE TABLE t(id INTEGER PRIMARY KEY, qty INTEGER)").run()
        try db.prepare("CREATE TABLE big(id INTEGER PRIMARY KEY, item INTEGER)").run()
        try db.prepare(
            """
            CREATE TRIGGER only_big AFTER INSERT ON t WHEN new.qty >= 10 BEGIN
              INSERT INTO big(item) VALUES(new.id);
            END
            """
        ).run()
        try db.prepare("INSERT INTO t(id, qty) VALUES(1, 5)").run()  // WHEN false → skip
        try db.prepare("INSERT INTO t(id, qty) VALUES(2, 20)").run()  // WHEN true → fire
        let rows = try db.prepare("SELECT item FROM big ORDER BY id").all().map(\.values)
        #expect(rows == [[.integer(2)]])
    }

    // MARK: - Deep-but-bounded recursion (the real headroom proof)

    /// (4a) Builds a chain t1→t2→…→t(maxDepth+1) via `maxDepth` AFTER-INSERT
    /// triggers (each inserts into the next table), then a single INSERT cascades
    /// through ALL `maxDepth` levels and completes WITHOUT crashing. A stack
    /// overflow is a hard crash that cannot be caught, so a test that nests to the
    /// cap and returns is the only real proof the dedicated writer thread's stack
    /// has the measured headroom. Must pass under both debug and ThreadSanitizer.
    @Test func deepTriggerChainCompletes() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("deepchain.adsql"))
        defer { db.close() }

        let depth = Int(TriggerEngine.maxDepth)
        // `depth` chain triggers over `depth + 1` tables: chain_i AFTER INSERT ON
        // t_i inserts into t_{i+1}. The top-level INSERT into t1 fires chain1 at
        // triggerDepth 0, chain2 at 1, …, chain(depth) at triggerDepth depth-1 —
        // the deepest the guard permits before tripping. So the cascade nests the
        // FULL `maxDepth` executor frames (chain(depth) inserts into t(depth+1),
        // which has no trigger, so it stops exactly at the cap without tripping it).
        for i in 1...(depth + 1) {
            try db.prepare("CREATE TABLE t\(i)(id INTEGER PRIMARY KEY, n INTEGER)").run()
        }
        for i in 1...depth {
            try db.prepare(
                """
                CREATE TRIGGER chain\(i) AFTER INSERT ON t\(i) BEGIN
                  INSERT INTO t\(i + 1)(id, n) VALUES(new.id, new.n + 1);
                END
                """
            ).run()
        }

        // One INSERT cascades through every level and returns normally.
        try db.prepare("INSERT INTO t1(id, n) VALUES(1, 0)").run()

        // Every table received exactly one row; the last carries the accumulated
        // hop count, proving the cascade ran end to end through all maxDepth levels.
        for i in 1...(depth + 1) {
            let count = try db.prepare("SELECT COUNT(*) FROM t\(i)").all()[0][0]
            #expect(count == .integer(1), "t\(i) should hold exactly one row")
        }
        let tail = try db.prepare("SELECT n FROM t\(depth + 1)").all()[0][0]
        #expect(tail == .integer(Int64(depth)), "tail hop count proves full cascade")

        _ = try db.verifyIntegrity(deep: true)
    }

    // MARK: - Recursion guard

    /// (4b) A self-referential trigger forms an unbounded chain; the depth guard
    /// must cut it off at `maxDepth` with a clean error AND roll the whole
    /// statement back (no partial chain persisted).
    @Test func selfReferentialTriggerErrorsRatherThanLooping() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("recurse.adsql"))
        defer { db.close() }
        try db.prepare("CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER)").run()
        // Each INSERT fires a trigger that INSERTs again with a different rowid:
        // an unbounded chain, which the depth guard must cut off with an error at
        // the new (raised) `maxDepth` rather than overflowing the writer's stack.
        try db.prepare(
            """
            CREATE TRIGGER loop AFTER INSERT ON t BEGIN
              INSERT INTO t(id, n) VALUES(new.id + 1, new.n + 1);
            END
            """
        ).run()
        do {
            try db.prepare("INSERT INTO t(id, n) VALUES(1, 1)").run()
            Issue.record("a self-referential trigger must error, not loop")
        } catch {
            guard case .sqlRuntime(let why) = error, why.contains("trigger recursion") else {
                Issue.record("expected trigger-recursion sqlRuntime, got \(error)")
                return
            }
        }
        // The whole statement rolled back: no partial chain persisted, regardless
        // of how many levels the guard allowed before tripping.
        let count = try db.prepare("SELECT COUNT(*) FROM t").all()[0][0]
        #expect(count == .integer(0))
    }
}

// MARK: - (4c) Concurrent writer stress

/// Hammers one Database with many concurrent writers via BOTH write paths
/// (`writeSync` on detached tasks and async `write`) and asserts the
/// `WriterThread` serial executor preserves the DispatchQueue contract:
/// mutual exclusion (every write lands; no lost/torn updates) and FIFO/atomic
/// application (a per-write running counter ends exactly at the write count).
/// Must be TSan-clean.
@Suite("Writer thread stress", .serialized)
struct WriterThreadStressTests {
    /// Each write reads a counter, increments it, writes it back — all inside one
    /// exclusive transaction. If the executor ever ran two writes concurrently or
    /// out of order against the same state, the final counter would fall short.
    @Test func concurrentWritesStayExclusiveAndComplete() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("stress.adsql"))
        defer { db.close() }

        let counterKey: [UInt8] = [0xC0]
        try db.writeSync { (txn) throws(DBError) in
            try txn.put(counterKey, le64(0))
        }

        let syncWriters = 8
        let syncPerWriter = 64
        let asyncWrites = 256
        let totalIncrements = syncWriters * syncPerWriter + asyncWrites

        // increment helper, run inside the exclusive write txn.
        @Sendable func bump(_ txn: borrowing WriteTxn) throws(DBError) {
            let current = try txn.get(counterKey).map(decodeLE64) ?? 0
            try txn.put(counterKey, le64(current + 1))
        }

        try await withThrowingTaskGroup(of: Void.self) { tasks in
            // Synchronous writers on detached threads (the writeSync path).
            for _ in 0..<syncWriters {
                tasks.addTask {
                    for _ in 0..<syncPerWriter {
                        try await Task.detached {
                            try db.writeSync { (txn) throws(DBError) in try bump(txn) }
                        }.value
                    }
                }
            }
            // Async group-commit writers (the write path).
            for i in 0..<asyncWrites {
                tasks.addTask {
                    try await db.write { (txn) throws(DBError) in
                        try bump(txn)
                        // Also land a unique key so we can independently count writes.
                        try txn.put(Array("w-\(i)".utf8), [UInt8(i & 0xFF)])
                    }
                }
            }
            try await tasks.waitForAll()
        }

        // Mutual exclusion + atomicity: no increment was lost.
        let final = try db.read { (txn) throws(DBError) in
            try txn.get(counterKey).map(decodeLE64) ?? 0
        }
        #expect(final == UInt64(totalIncrements), "lost or torn update: \(final) != \(totalIncrements)")

        // Every async writer's unique key is present (all writes durably landed).
        let asyncLanded = try db.read { (txn) throws(DBError) in
            var found = 0
            for i in 0..<asyncWrites where try txn.contains(Array("w-\(i)".utf8)) { found += 1 }
            return found
        }
        #expect(asyncLanded == asyncWrites)

        _ = try db.verifyIntegrity(deep: true)
    }

    /// Regression for the writer-thread teardown self-join. A group-commit drain
    /// captures `Database` strongly (`[self]`), so the worker can drop the last
    /// reference when it frees that closure — running `Database.deinit` →
    /// `WriterThread.shutdown()` ON the writer thread. `shutdown()` must detach
    /// there instead of `pthread_join`-ing itself; otherwise this loop deadlocks.
    /// Open → one async `write` → drop the handle, many times, so `deinit`
    /// repeatedly races the in-flight drain's final release on the writer thread.
    @Test func handleTeardownRacingInFlightDrainDoesNotDeadlock() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        for i in 0..<200 {
            let db = try Database.open(at: dir.file("teardown-\(i).adsql"))
            try await db.write { (txn) throws(DBError) in try txn.put([0x01], le64(UInt64(i))) }
            // `db` leaves scope here: its `deinit` races the drain job's `body = nil`
            // release on the writer thread. A regression would hang on a self-join.
        }
    }
}

private func le64(_ value: UInt64) -> [UInt8] {
    var v = value.littleEndian
    return withUnsafeBytes(of: &v) { Array($0) }
}

private func decodeLE64(_ bytes: [UInt8]) -> UInt64 {
    var v: UInt64 = 0
    withUnsafeMutableBytes(of: &v) { dst in
        dst.copyBytes(from: bytes.prefix(8))
    }
    return UInt64(littleEndian: v)
}

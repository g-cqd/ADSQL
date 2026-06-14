import ADSQLTestSupport
import Testing

@testable import ADSQLKernel

@Suite("SQL PRAGMA compatibility")
struct SQLPragmaTests {
    /// A SQLite consumer's connection-setup script must run unchanged.
    @Test func setupScriptNeverErrors() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("pragma.adsql"))
        defer { db.close() }

        for sql in [
            "PRAGMA journal_mode = WAL",
            "PRAGMA synchronous = OFF",
            "PRAGMA foreign_keys = ON",
            "PRAGMA mmap_size = 10737418240",
            "PRAGMA cache_size = -64000",
            "PRAGMA temp_store = MEMORY",
            "PRAGMA query_only = 1",
            "PRAGMA user_version = 27",
        ] {
            // Setters accept and return no rows.
            #expect(try db.prepare(sql).all().isEmpty, "\(sql)")
        }
    }

    @Test func gettersReturnOneRow() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("pragma-get.adsql"))
        defer { db.close() }

        #expect(try db.prepare("PRAGMA foreign_keys").all().first?.values == [.integer(1)])
        #expect(try db.prepare("PRAGMA page_size").all().first?[0] == .integer(16384))
        #expect(try db.prepare("PRAGMA journal_mode").all().first?.values == [.text("wal")])
        // Parenthesized form parses as a setter (no-op).
        #expect(try db.prepare("PRAGMA cache_size(2000)").all().isEmpty)
    }

    @Test func unknownPragmaIsSilent() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("pragma-unknown.adsql"))
        defer { db.close() }
        #expect(try db.prepare("PRAGMA not_a_real_pragma").all().isEmpty)
        #expect(try db.prepare("PRAGMA wal_checkpoint(FULL)").all().isEmpty)
    }
}

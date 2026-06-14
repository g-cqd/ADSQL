import ADSQLTestSupport
import CSQLite
import Testing

@testable import ADSQLKernel

/// Correlated and uncorrelated scalar subqueries over roots(id, slug) and
/// pages(id, root_id, title): root 1 has two pages, root 2 one, root 3 none.
@Suite("SQL scalar subqueries")
struct SQLSubqueryTests {
    private static let setup = [
        "CREATE TABLE roots(id INTEGER PRIMARY KEY, slug TEXT)",
        "CREATE TABLE pages(id INTEGER PRIMARY KEY, root_id INTEGER, title TEXT)",
        "INSERT INTO roots VALUES(1,'UIKit'),(2,'SwiftUI'),(3,'Empty')",
        "INSERT INTO pages VALUES(1,1,'a'),(2,1,'b'),(3,2,'c')",
    ]

    private func build() throws -> (Database, SQLiteMirror, TempDir) {
        let dir = TempDir()
        let db = try Database.open(at: dir.file("subq.adsql"))
        let mirror = SQLiteMirror()
        for sql in Self.setup {
            try db.prepare(sql).run()
            try mirror.exec(sql)
        }
        return (db, mirror, dir)
    }

    static let queries: [String] = [
        // correlated COUNT(*) in the output
        "SELECT id, slug, (SELECT COUNT(*) FROM pages WHERE pages.root_id = roots.id) AS n FROM roots ORDER BY id",
        // correlated subquery in WHERE
        "SELECT id FROM roots WHERE (SELECT COUNT(*) FROM pages WHERE pages.root_id = roots.id) > 0 ORDER BY id",
        "SELECT id FROM roots WHERE (SELECT COUNT(*) FROM pages WHERE pages.root_id = roots.id) = 0 ORDER BY id",
        // correlated non-aggregate subquery: first page title, NULL when empty
        "SELECT id, (SELECT title FROM pages WHERE pages.root_id = roots.id ORDER BY id LIMIT 1) AS first FROM roots ORDER BY id",
        // uncorrelated scalar subquery (same value for every outer row)
        "SELECT id, (SELECT COUNT(*) FROM pages) AS total FROM roots ORDER BY id",
        // correlated subquery feeding an expression
        "SELECT slug, (SELECT COUNT(*) FROM pages WHERE pages.root_id = roots.id) * 10 AS scaled FROM roots ORDER BY id",
        // correlated SUM (NULL when no rows)
        "SELECT id, (SELECT SUM(p.id) FROM pages p WHERE p.root_id = roots.id) AS s FROM roots ORDER BY id",
    ]

    @Test(arguments: queries)
    func matchesSQLite(_ sql: String) throws {
        let (db, mirror, dir) = try build()
        defer {
            dir.cleanup()
            db.close()
        }
        let ours = try db.prepare(sql).all().map(\.values)
        let theirs = try mirror.query(sql)
        #expect(rowsMatch(ours, theirs, ordered: true), "\(sql): adsql \(ours) vs sqlite \(theirs)")
    }
}

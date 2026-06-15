import ADSQL
import ADSQLImport
import ADSQLTestSupport
import CSQLite
import Testing

/// F6 build-time denormalization through the importer (RFC 0010): a manifest `Denorm`
/// spec makes `Database.importSQLite` create + populate the apple-docs `/search` denorm
/// columns directly — the productionized form of what the bench validated as a ~2.2×
/// win over SQLite at 8-way. Per-row columns (`LOWER`/`CAST`/`json_extract`) + the
/// `root_display` roots lookup (+ framework fallback) + `root_slug = framework`.
@Suite("F6 denorm via importer")
struct DenormImportTests {
    /// apple-docs-shaped source: `documents` (+ JSON `source_metadata`) and `roots`.
    private func makeSource(at path: String) throws {
        var db: OpaquePointer?
        try #require(
            sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        for sql in [
            "CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT, key TEXT, framework TEXT, source_metadata TEXT)",
            "CREATE TABLE roots(slug TEXT PRIMARY KEY, display_name TEXT)",
            "INSERT INTO roots VALUES ('swiftui', 'SwiftUI'), ('uikit', 'UIKit')",
            """
            INSERT INTO documents VALUES
              (1, 'View Basics', 'doc://SwiftUI/View', 'swiftui', '{"year":2019,"track":"UI"}'),
              (2, 'Button', 'doc://UIKit/Button', 'uikit', '{"year":2014}'),
              (3, 'Mystery', 'doc://X/Y', 'unknownfw', '{}')
            """,
        ] {
            try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "exec: \(sql)")
        }
    }

    private var manifest: ImportManifest {
        ImportManifest(denorm: [
            ImportManifest.Denorm(
                table: "documents",
                columns: [
                    .init(name: "title_lc", type: .text, valueSQL: "LOWER(title)"),
                    .init(name: "key_lc", type: .text, valueSQL: "LOWER(key)"),
                    .init(
                        name: "year_num", type: .integer,
                        valueSQL: "CAST(json_extract(source_metadata, '$.year') AS INTEGER)"),
                    .init(
                        name: "track_lc", type: .text,
                        valueSQL: "LOWER(COALESCE(json_extract(source_metadata, '$.track'), ''))"),
                    .init(name: "root_slug", type: .text, valueSQL: "framework"),
                ],
                lookups: [
                    .init(
                        name: "root_display", type: .text, matchColumn: "framework",
                        lookupTable: "roots", lookupKey: "slug", lookupValue: "display_name",
                        fallbackColumn: "framework")
                ])
        ])
    }

    @Test func importPopulatesDenormColumns() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let source = dir.file("source.db")
        try makeSource(at: source)

        let db = try Database.open(at: dir.file("out.adsql"))
        defer { db.close() }
        _ = try db.importSQLite(from: source, manifest: manifest)

        func row(_ id: Int64) throws -> SQLRow {
            try #require(
                try db.prepare(
                    """
                    SELECT title_lc, key_lc, year_num, track_lc, root_display, root_slug
                    FROM documents WHERE id = ?
                    """
                ).get(.integer(id)))
        }
        let r1 = try row(1)
        #expect(r1["title_lc"] == .text("view basics"))
        #expect(r1["key_lc"] == .text("doc://swiftui/view"))
        #expect(r1["year_num"] == .integer(2019))
        #expect(r1["track_lc"] == .text("ui"))
        #expect(r1["root_display"] == .text("SwiftUI"))  // roots lookup hit
        #expect(r1["root_slug"] == .text("swiftui"))

        let r2 = try row(2)
        #expect(r2["year_num"] == .integer(2014))
        #expect(r2["track_lc"] == .text(""))  // missing track → ''
        #expect(r2["root_display"] == .text("UIKit"))

        let r3 = try row(3)
        #expect(r3["year_num"] == .null)  // missing year → NULL
        #expect(r3["track_lc"] == .text(""))
        #expect(r3["root_display"] == .text("unknownfw"))  // no root → framework fallback
        #expect(r3["root_slug"] == .text("unknownfw"))

        // Original columns survive the denorm pass intact.
        let original = try row(1)
        #expect(try db.prepare("SELECT title FROM documents WHERE id = 1").get()?["title"] == .text("View Basics"))
        _ = original
    }
}

import ADSQLTestSupport
import Testing

@testable import ADSQLKernel

/// Feasibility/regression for productionizing **F6 denormalization via the importer**
/// (RFC 0010): a `documents` table created WITH the six denorm columns (ADSQL has no
/// ALTER TABLE) is populated by `UPDATE … SET col = <expr>` using ADSQL's own engine —
/// `LOWER` / `CAST` / `json_extract` / `COALESCE` per-row, plus the `root_display`
/// roots lookup. Pins that every denorm expression the apple-docs `/search` denorm
/// query depends on is computable in-engine (so the importer can build the denorm
/// corpus directly instead of relying on source-side SQL).
@Suite("F6 denorm via UPDATE")
struct SQLDenormUpdateTests {
    @Test func denormColumnsPopulateViaUpdate() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("denorm.adsql"))
        defer { db.close() }

        for ddl in [
            """
            CREATE TABLE documents(
              id INTEGER PRIMARY KEY, title TEXT, key TEXT, framework TEXT,
              source_metadata TEXT,
              title_lc TEXT, key_lc TEXT, year_num INTEGER, track_lc TEXT,
              root_display TEXT, root_slug TEXT)
            """,
            "CREATE TABLE roots(slug TEXT PRIMARY KEY, display_name TEXT)",
        ] {
            try db.prepare(ddl).run()
        }
        try db.prepare("INSERT INTO roots(slug, display_name) VALUES('swiftui', 'SwiftUI')").run()
        try db.prepare("INSERT INTO roots(slug, display_name) VALUES('uikit', 'UIKit')").run()

        // (id, title, key, framework, source_metadata)
        let rows: [(Int64, String, String, String, String)] = [
            (1, "View Basics", "doc://SwiftUI/View", "swiftui", #"{"year":2019,"track":"UI"}"#),
            (2, "Button", "doc://UIKit/Button", "uikit", #"{"year":2014}"#),  // no track
            (3, "Mystery", "doc://X/Y", "unknownfw", "{}"),  // no root, no year/track
        ]
        for (id, title, key, fw, meta) in rows {
            try db.prepare(
                "INSERT INTO documents(id, title, key, framework, source_metadata) VALUES(?, ?, ?, ?, ?)"
            ).run(.integer(id), .text(title), .text(key), .text(fw), .text(meta))
        }

        // Per-row denorm (the 4 transforms + root_slug = framework, which holds because
        // the roots join is r.slug = d.framework so the matched slug IS the framework).
        try db.prepare(
            """
            UPDATE documents SET
              title_lc = LOWER(title),
              key_lc = LOWER(key),
              year_num = CAST(json_extract(source_metadata, '$.year') AS INTEGER),
              track_lc = LOWER(COALESCE(json_extract(source_metadata, '$.track'), '')),
              root_slug = framework
            """
        ).run()
        // root_display = COALESCE(<roots.display_name for this framework>, framework).
        // ADSQL has no correlated-subquery UPDATE, so populate per-root (roots is small:
        // ~435 rows) then fill the still-NULL rows with the framework fallback. This is
        // the shape the importer will use (reading the imported `roots` rows).
        for r in try db.prepare("SELECT slug, display_name FROM roots").all() {
            try db.prepare("UPDATE documents SET root_display = ? WHERE framework = ?")
                .run(r["display_name"] ?? .null, r["slug"] ?? .null)
        }
        try db.prepare("UPDATE documents SET root_display = framework WHERE root_display IS NULL").run()

        func row(_ id: Int64) throws -> SQLRow {
            try #require(try db.prepare("SELECT * FROM documents WHERE id = ?").get(.integer(id)))
        }
        let r1 = try row(1)
        #expect(r1["title_lc"] == .text("view basics"))
        #expect(r1["key_lc"] == .text("doc://swiftui/view"))
        #expect(r1["year_num"] == .integer(2019))
        #expect(r1["track_lc"] == .text("ui"))
        #expect(r1["root_display"] == .text("SwiftUI"))  // roots lookup hit
        #expect(r1["root_slug"] == .text("swiftui"))

        let r2 = try row(2)
        #expect(r2["track_lc"] == .text(""))  // missing track → COALESCE('') → ''
        #expect(r2["root_display"] == .text("UIKit"))
        #expect(r2["year_num"] == .integer(2014))

        let r3 = try row(3)
        #expect(r3["year_num"] == .null)  // missing year → json_extract NULL → CAST NULL
        #expect(r3["track_lc"] == .text(""))
        #expect(r3["root_display"] == .text("unknownfw"))  // no root → COALESCE fallback to framework
        #expect(r3["root_slug"] == .text("unknownfw"))
    }
}

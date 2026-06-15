import ADSQL
import ADSQLImport
import ADSQLTestSupport
import CSQLite
import Testing

/// The shared apple-docs-shaped corpus + harness for the RFC 0010 §2 parity tests.
///
/// Both `AppleDocsMainQueryTests` (the §2.2–2.4 byte-parity-vs-SQLite harness) and
/// `SearchPagesFramedTests` (the M8 INT framed-output proof) build the SAME small
/// SQLite fixture, import it into ADSQL, and diff against the SQLite oracle running
/// the identical §2.2 query — so the fixture, the manifest, the import harness, and
/// the SQLite-oracle decode live here once.
///
/// "Apple-docs-shaped" means the §2.1 read schema (`documents` + `roots` +
/// `documents_fts`) seeded with ~30 deterministic rows hand-tuned so every tier
/// (0/1/2/3) and every §2.4 filter discriminates: exact/prefix/substring titles,
/// frameworks both present in `roots` (LEFT JOIN hit) and absent (COALESCE
/// fallback), `source_type ∈ {doc,wwdc,sample}`, `source_metadata` JSON with
/// year/track, toggled `is_deprecated`/`is_beta`, `language ∈ {swift,occ,both}`,
/// and varied `min_*_num` (including NULLs).
enum AppleDocsFixture {
    /// The FTS5 reconstruction manifest: `documents_fts` ←
    /// `documents.[title,abstract_text,declaration_text,headings,key]`,
    /// `tokenize='porter unicode61'` — matching `buildFixture`'s source FTS table.
    static let manifest = ImportManifest(ftsTables: [
        .init(
            name: "documents_fts",
            columns: ["title", "abstract", "declaration", "headings", "key"],
            tokenize: ["porter", "unicode61"],
            source: .init(
                table: "documents",
                columns: ["title", "abstract_text", "declaration_text", "headings", "key"]))
    ])

    /// (`$query`, `$raw`) probe pairs chosen to exercise every tier:
    ///   - "swiftui"/"SwiftUI" — exact title-prefix + framework anchor (tiers 0/1/2).
    ///   - "view"/"View"       — broad substring across many titles (tier 1/2/3).
    ///   - "async"/"AsyncSequence" — prefix + substring against the seeded titles.
    ///   - "data"/"Data"       — exact + substring.
    ///   - "render"/"render"   — body/abstract-only porter stem (tier 3, rank spread).
    static let probes: [(String, String)] = [
        ("swiftui", "SwiftUI"),
        ("view", "View"),
        ("async", "AsyncSequence"),
        ("data", "Data"),
        ("render", "render"),
    ]

    /// The 13 §2.4 filter param names (NULL-guarded), with the `deprecated_mode`
    /// pair split into the `$dep_exclude` / `$dep_only` guard ints apple-docs binds.
    static let filterKeys = [
        "framework", "source_type", "sources_json", "kind", "language", "year",
        "track_like", "dep_exclude", "dep_only", "min_ios", "min_macos",
        "min_watchos", "min_tvos", "min_visionos",
    ]

    /// The transient (`SQLITE_TRANSIENT`) destructor for `sqlite3_bind_text/_blob`.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Harness

    /// Builds the apple-docs-shaped SQLite fixture, imports it into a fresh ADSQL
    /// database, and hands both to `body`. The source SQLite handle stays open as
    /// the diff oracle.
    static func withImportedCorpus(
        _ body: (Database, OpaquePointer?) throws -> Void
    ) throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let sourcePath = dir.file("appledocs.db")

        var src: OpaquePointer?
        try #require(
            sqlite3_open_v2(sourcePath, &src, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK)
        defer { sqlite3_close_v2(src) }
        try buildFixture(src)

        let db = try Database.open(at: dir.file("out.adsql"))
        defer { db.close() }
        _ = try db.importSQLite(from: sourcePath, manifest: manifest)

        try body(db, src)
    }

    /// Creates the §2.1 read schema (documents + roots + documents_fts) and seeds
    /// the deterministic rows. The FTS table is populated from `documents` exactly
    /// as the importer reconstructs it.
    static func buildFixture(_ db: OpaquePointer?) throws {
        try exec(
            db,
            """
            CREATE TABLE documents(
              id INTEGER PRIMARY KEY,
              key TEXT, title TEXT, role TEXT, role_heading TEXT,
              abstract_text TEXT, declaration_text TEXT, headings TEXT,
              platforms_json TEXT,
              min_ios_num INTEGER, min_macos_num INTEGER, min_watchos_num INTEGER,
              min_tvos_num INTEGER, min_visionos_num INTEGER,
              min_ios TEXT, min_macos TEXT, min_watchos TEXT, min_tvos TEXT, min_visionos TEXT,
              framework TEXT, source_type TEXT, source_metadata TEXT,
              is_deprecated INTEGER, is_beta INTEGER, is_release_notes INTEGER,
              kind TEXT, language TEXT, url_depth INTEGER)
            """)
        try exec(db, "CREATE TABLE roots(slug TEXT PRIMARY KEY, display_name TEXT)")
        // roots covers some frameworks (so the LEFT JOIN hits) and deliberately
        // omits others (so COALESCE falls back to d.framework, and r.* is NULL).
        for (slug, name) in [
            ("swiftui", "SwiftUI"), ("uikit", "UIKit"), ("foundation", "Foundation"),
            ("combine", "Combine"),
        ] {
            try exec(db, "INSERT INTO roots VALUES ('\(slug)', '\(name)')")
        }

        for doc in seedRows() {
            try exec(db, doc.insertSQL())
        }

        try exec(
            db,
            """
            CREATE VIRTUAL TABLE documents_fts USING fts5(
              title, abstract, declaration, headings, key, tokenize='porter unicode61')
            """)
        try exec(
            db,
            """
            INSERT INTO documents_fts(rowid, title, abstract, declaration, headings, key)
            SELECT id, title, abstract_text, declaration_text, headings, key FROM documents
            """)
    }

    static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        let detail = message.map { String(cString: $0) } ?? ""
        sqlite3_free(message)
        try #require(rc == SQLITE_OK, "exec failed (\(rc)): \(detail)\nSQL: \(sql)")
    }

    // MARK: - Engines

    /// Runs `sql` with named `params` against ADSQL and returns positional rows.
    static func adsqlRows(
        _ db: Database, _ sql: String, _ params: [String: Value]
    ) throws -> [[Value]] {
        try db.prepare(sql).all(params).map(\.values)
    }

    /// The SQLite oracle: prepare `sql`, bind every `$name` param by index (resolved
    /// via `sqlite3_bind_parameter_index`), step, and read each cell into a `Value`
    /// with the same storage-class dispatch the importer uses.
    static func sqliteRows(
        _ db: OpaquePointer?, _ sql: String, _ params: [String: Value]
    ) -> [[Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("sqlite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        for (name, value) in params {
            let index = sqlite3_bind_parameter_index(stmt, "$" + name)
            guard index > 0 else { continue }  // unused param in this query variant
            switch value {
            case .null: sqlite3_bind_null(stmt, index)
            case .integer(let v): sqlite3_bind_int64(stmt, index, v)
            case .real(let d): sqlite3_bind_double(stmt, index, d)
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
            case .blob(let b):
                _ = b.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), transient)
                }
            }
        }
        let columnCount = Int(sqlite3_column_count(stmt))
        var rows: [[Value]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Value] = []
            row.reserveCapacity(columnCount)
            for col in 0..<Int32(columnCount) {
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_NULL: row.append(.null)
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(stmt, col)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(stmt, col)))
                case SQLITE_TEXT:
                    row.append(.text(String(cString: sqlite3_column_text(stmt, col))))
                default:
                    let count = Int(sqlite3_column_bytes(stmt, col))
                    if count > 0, let base = sqlite3_column_blob(stmt, col) {
                        row.append(.blob([UInt8](UnsafeRawBufferPointer(start: base, count: count))))
                    } else {
                        row.append(.blob([]))
                    }
                }
            }
            rows.append(row)
        }
        return rows
    }
}

extension Value {
    /// The numeric payload as a Double (for the bm25 rank tolerance compare). nil
    /// for non-numeric values.
    var doubleValue: Double? {
        switch self {
        case .real(let d): return d
        case .integer(let v): return Double(v)
        default: return nil
        }
    }
}

// MARK: - Seed corpus (apple-docs-shaped, hand-tuned for tier + filter coverage)

extension AppleDocsFixture {
    /// One `documents` row, with the §2.1 read columns. SQL-literal escaping is
    /// limited to single quotes (the only quote the seeds use); the corpus is fixed
    /// so this is sufficient and keeps the fixture Foundation-free.
    struct AppleDoc {
        var id: Int64
        var key: String
        var title: String
        var role: String
        var roleHeading: String
        var abstract: String
        var declaration: String
        var headings: String
        var platformsJSON: String
        var minIOS: Int64?
        var minMacOS: Int64?
        var minWatchOS: Int64?
        var minTVOS: Int64?
        var minVisionOS: Int64?
        var framework: String
        var sourceType: String
        var sourceMetadata: String
        var isDeprecated: Int64
        var isBeta: Int64
        var isReleaseNotes: Int64
        var kind: String
        var language: String
        var urlDepth: Int64

        func insertSQL() -> String {
            // Single-quote-doubling SQL string literal (Foundation-free, per-character),
            // matching the importer's own `doubling` escaper.
            func text(_ s: String) -> String {
                var out = "'"
                out.reserveCapacity(s.count + 2)
                for character in s {
                    out.append(character)
                    if character == "'" { out.append(character) }
                }
                out.append("'")
                return out
            }
            func num(_ v: Int64?) -> String { v.map(String.init) ?? "NULL" }
            // The text platform mirrors (min_ios .. min_visionos) carry the SDK-style
            // string; left empty here (the read path reads the *_num columns).
            return """
                INSERT INTO documents(
                  id, key, title, role, role_heading, abstract_text, declaration_text, headings,
                  platforms_json, min_ios_num, min_macos_num, min_watchos_num, min_tvos_num,
                  min_visionos_num, min_ios, min_macos, min_watchos, min_tvos, min_visionos,
                  framework, source_type, source_metadata, is_deprecated, is_beta,
                  is_release_notes, kind, language, url_depth)
                VALUES (\(id), \(text(key)), \(text(title)), \(text(role)), \(text(roleHeading)),
                  \(text(abstract)), \(text(declaration)), \(text(headings)), \(text(platformsJSON)),
                  \(num(minIOS)), \(num(minMacOS)), \(num(minWatchOS)), \(num(minTVOS)), \(num(minVisionOS)),
                  '', '', '', '', '',
                  \(text(framework)), \(text(sourceType)), \(text(sourceMetadata)),
                  \(isDeprecated), \(isBeta), \(isReleaseNotes), \(text(kind)), \(text(language)), \(urlDepth))
                """
        }
    }

    /// ~30 deterministic rows tuned so every tier and every filter discriminates.
    static func seedRows() -> [AppleDoc] {
        var rows: [AppleDoc] = []
        func add(
            _ key: String, _ title: String, role: String = "symbol", roleHeading: String = "Symbol",
            abstract: String, declaration: String = "", headings: String = "Overview Topics",
            platforms: String = "[]", framework: String, sourceType: String = "doc",
            metadata: String = "{}", ios: Int64? = nil, macos: Int64? = nil, watchos: Int64? = nil,
            tvos: Int64? = nil, visionos: Int64? = nil, deprecated: Int64 = 0, beta: Int64 = 0,
            releaseNotes: Int64 = 0, kind: String = "symbol", language: String = "swift", depth: Int64 = 3
        ) {
            rows.append(
                AppleDoc(
                    id: Int64(rows.count + 1), key: key, title: title, role: role,
                    roleHeading: roleHeading, abstract: abstract, declaration: declaration,
                    headings: headings, platformsJSON: platforms, minIOS: ios, minMacOS: macos,
                    minWatchOS: watchos, minTVOS: tvos, minVisionOS: visionos, framework: framework,
                    sourceType: sourceType, sourceMetadata: metadata, isDeprecated: deprecated,
                    isBeta: beta, isReleaseNotes: releaseNotes, kind: kind, language: language,
                    urlDepth: depth))
        }

        // Tier-0 exact titles for the probe raws.
        add(
            "doc/swiftui", "SwiftUI", role: "collection", roleHeading: "Framework",
            abstract: "Declarative UI framework. Build the view hierarchy with structured state.",
            declaration: "", framework: "swiftui", sourceType: "doc",
            metadata: "{\"year\":2024,\"track\":\"SwiftUI Essentials\"}", ios: 26, macos: 15,
            kind: "collection", depth: 1)
        add(
            "doc/swiftui/view", "View", abstract: "A type that represents part of your app's UI.",
            declaration: "protocol View", framework: "swiftui", sourceType: "doc",
            metadata: "{\"year\":2023,\"track\":\"Graphics and Drawing\"}", ios: 17, macos: 14,
            visionos: 2, kind: "symbol")
        add(
            "doc/foundation/data", "Data", abstract: "A byte buffer in memory.",
            declaration: "struct Data", framework: "foundation", sourceType: "doc",
            metadata: "{\"year\":2024}", ios: 26, macos: 15, watchos: 11, tvos: 18, kind: "symbol",
            language: "occ")
        add(
            "doc/combine/asyncsequence", "AsyncSequence",
            abstract: "A sequence that provides values asynchronously over time.",
            declaration: "protocol AsyncSequence", framework: "combine", sourceType: "doc",
            metadata: "{\"year\":2023,\"track\":\"Swift Concurrency\"}", ios: 17, kind: "symbol")

        // Tier-1 title-prefix matches.
        add(
            "doc/swiftui/viewbuilder", "ViewBuilder",
            abstract: "A result builder for composing views from closures.",
            declaration: "struct ViewBuilder", framework: "swiftui", ios: 26, macos: 15, kind: "symbol")
        add(
            "doc/swiftui/viewmodifier", "ViewModifier deprecated shim",
            abstract: "Adapts a view. This older entry is deprecated.",
            declaration: "protocol ViewModifier", framework: "swiftui", sourceType: "doc",
            metadata: "{\"year\":2019}", deprecated: 1, kind: "symbol", depth: 4)
        add(
            "doc/uikit/asyncimage", "AsyncImage view",
            abstract: "A view that loads and displays an image asynchronously.",
            declaration: "struct AsyncImage", framework: "uikit", sourceType: "doc", ios: 26, macos: 15,
            kind: "symbol", language: "both")

        // Tier-2 title-substring matches (term not at the start).
        add(
            "doc/swiftui/navigationview", "Legacy NavigationView container",
            abstract: "A deprecated container for a view stack.",
            declaration: "struct NavigationView", framework: "swiftui", sourceType: "doc",
            metadata: "{\"year\":2019,\"track\":\"SwiftUI Essentials\"}", ios: 13, deprecated: 1,
            kind: "symbol", depth: 4)
        add(
            "doc/metal/textureview", "MTL Texture view helper",
            abstract: "Wraps a metal texture for rendering.",
            declaration: "struct TextureView", framework: "Metal", sourceType: "sample",
            metadata: "{\"year\":2022}", ios: 16, macos: 13, kind: "sample", depth: 3)
        add(
            "doc/coredata/fetcheddata", "Working with FetchedData",
            abstract: "Read managed data from the store.",
            declaration: "class FetchedData", framework: "CoreData", sourceType: "doc",
            metadata: "{\"year\":2021}", ios: 15, macos: 12, kind: "article", language: "both", depth: 2)

        // Tier-3 abstract/declaration/heading-only matches (no title hit).
        add(
            "doc/swiftui/state", "State",
            abstract: "A property wrapper that creates a view-local source of truth that the view renders.",
            declaration: "struct State conforms to DynamicProperty", headings: "Overview Declaration",
            framework: "swiftui", sourceType: "doc", metadata: "{\"year\":2024}", ios: 26, macos: 15,
            kind: "symbol")
        add(
            "doc/metal/renderpipeline", "MTLRenderPipelineState",
            abstract: "Encapsulates the compiled render pipeline. The renderer binds it per draw.",
            declaration: "protocol MTLRenderPipelineState", framework: "Metal", sourceType: "doc",
            metadata: "{\"year\":2022,\"track\":\"Graphics and Drawing\"}", ios: 16, macos: 13,
            kind: "symbol")
        add(
            "doc/combine/publisher", "Publisher",
            abstract: "Declares that a type transmits a sequence of values to subscribers asynchronously.",
            declaration: "protocol Publisher", framework: "combine", sourceType: "doc",
            metadata: "{\"year\":2019}", ios: 13, macos: 10, deprecated: 0, kind: "symbol", language: "occ")
        add(
            "doc/foundation/jsondecoder", "JSONDecoder",
            abstract: "Decodes data values from JSON. Often used to render a model from a response.",
            declaration: "class JSONDecoder", framework: "foundation", sourceType: "doc",
            metadata: "{\"year\":2017}", ios: 13, macos: 10, watchos: 6, tvos: 13, kind: "symbol")

        // WWDC-track + beta + release-notes rows (filter coverage).
        add(
            "wwdc/2024/10144", "Demystify SwiftUI performance",
            role: "article", roleHeading: "Article",
            abstract: "A session on keeping the view body fast and avoiding render churn.",
            declaration: "", headings: "Overview Resources", framework: "swiftui", sourceType: "wwdc",
            metadata: "{\"year\":2024,\"track\":\"SwiftUI & UI Frameworks\"}", ios: 26, macos: 15, beta: 1,
            kind: "article", language: "both", depth: 2)
        add(
            "wwdc/2023/10149", "Build async data flows",
            role: "article", roleHeading: "Article",
            abstract: "Use AsyncSequence to render data as it streams in.",
            declaration: "", framework: "combine", sourceType: "wwdc",
            metadata: "{\"year\":2023,\"track\":\"Swift Concurrency\"}", ios: 17, kind: "article",
            language: "both", depth: 2)
        add(
            "doc/releasenotes/ios26", "iOS 26 Release Notes",
            role: "article", roleHeading: "Article",
            abstract: "What changed for the SwiftUI view system and data APIs.",
            declaration: "", framework: "swiftui", sourceType: "doc",
            metadata: "{\"year\":2025}", ios: 26, releaseNotes: 1, kind: "article", language: "both",
            depth: 2)

        // A few extra prose-only rows to widen bm25 spread + length normalization.
        add(
            "doc/uikit/uiview", "UIView",
            abstract: "An object that manages the content for a rectangular area, the base view class.",
            declaration: "class UIView", framework: "uikit", sourceType: "doc",
            metadata: "{\"year\":2014}", ios: 13, tvos: 13, deprecated: 0, kind: "symbol", language: "occ",
            depth: 2)
        add(
            "doc/uikit/uiviewcontroller", "UIViewController",
            abstract: "An object that manages a view hierarchy for your UIKit app.",
            declaration: "class UIViewController", framework: "uikit", sourceType: "doc",
            metadata: "{\"year\":2014}", ios: 13, tvos: 13, kind: "symbol", language: "occ", depth: 2)
        add(
            "doc/swiftdata/model", "Model macro",
            abstract: "Defines and renders a SwiftData model type from a class.",
            declaration: "macro Model", framework: "SwiftData", sourceType: "doc",
            metadata: "{\"year\":2023}", ios: 17, macos: 14, kind: "symbol")
        add(
            "doc/swiftui/grid", "Grid",
            abstract: "A container view that arranges other views in a two-dimensional layout.",
            declaration: "struct Grid", framework: "swiftui", sourceType: "doc",
            metadata: "{\"year\":2022}", ios: 16, macos: 13, kind: "symbol")
        add(
            "doc/swiftui/list", "List",
            abstract: "A container that presents rows of data arranged in a single column.",
            declaration: "struct List", framework: "swiftui", sourceType: "doc",
            metadata: "{\"year\":2019}", ios: 13, macos: 10, kind: "symbol")
        add(
            "doc/metal/buffer", "MTLBuffer",
            abstract: "A resource that stores data for the GPU. The renderer reads it during a pass.",
            declaration: "protocol MTLBuffer", framework: "Metal", sourceType: "doc",
            metadata: "{\"year\":2014}", ios: 13, macos: 10, deprecated: 0, kind: "symbol")
        add(
            "doc/coredata/persistentcontainer", "NSPersistentContainer",
            abstract: "A container that encapsulates the Core Data stack and loads the data store.",
            declaration: "class NSPersistentContainer", framework: "CoreData", sourceType: "doc",
            metadata: "{\"year\":2016}", ios: 13, macos: 10, kind: "symbol", language: "occ")
        add(
            "doc/foundation/url", "URL",
            abstract: "A value that identifies the location of a resource, such as a data file.",
            declaration: "struct URL", framework: "foundation", sourceType: "doc",
            metadata: "{\"year\":2016}", ios: 13, macos: 10, watchos: 6, tvos: 13, kind: "symbol")
        add(
            "doc/observation/observable", "Observable macro",
            abstract: "Marks a type as observable so a SwiftUI view re-renders on data changes.",
            declaration: "macro Observable", framework: "Observation", sourceType: "doc",
            metadata: "{\"year\":2023,\"track\":\"Swift Concurrency\"}", ios: 17, macos: 14, kind: "symbol")
        add(
            "doc/swiftui/scrollview", "ScrollView",
            abstract: "A scrollable view that renders its content lazily as the user scrolls.",
            declaration: "struct ScrollView", framework: "swiftui", sourceType: "doc",
            metadata: "{\"year\":2019}", ios: 13, macos: 10, visionos: 2, kind: "symbol")
        add(
            "doc/swiftui/asynccontent", "Loading async content",
            role: "article", roleHeading: "Article",
            abstract: "Render placeholder views while you load data asynchronously.",
            declaration: "", framework: "swiftui", sourceType: "doc",
            metadata: "{\"year\":2024,\"track\":\"SwiftUI Essentials\"}", ios: 26, kind: "article",
            language: "both", depth: 3)

        return rows
    }
}

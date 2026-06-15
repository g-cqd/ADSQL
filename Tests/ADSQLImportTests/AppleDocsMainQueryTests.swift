import ADSQL
import ADSQLImport
import ADSQLTestSupport
import CSQLite
import Testing

/// M8 (RFC 0010 §2) — apple-docs "main" search-query byte-parity verification.
///
/// This is a VERIFY-AND-REPORT harness, not a feature build: it constructs a small
/// apple-docs-shaped SQLite corpus, imports it into ADSQL via `db.importSQLite`, and
/// runs the §2.2 hot-path query (5-weight `bm25` + `tier` CASE + `JOIN documents` +
/// `LEFT JOIN roots` + the §2.3 24-column projection + `ORDER BY tier, rank LIMIT`)
/// against BOTH the source SQLite (the oracle) and ADSQL, then diffs the result rows
/// for value + order parity (with `bm25` rank compared within 1e-9 relative).
///
/// Each of the §2.4 filter predicates is then layered on incrementally and diffed,
/// so the readiness of every clause is independently pinned. The `inJSONEach`
/// (`d.source_type IN (SELECT value FROM json_each($sources_json))`) clause is
/// exercised via ADSQL's *self-contained* `inJSONEach` AST node (parsed from the
/// contracted shape, evaluated by `SQLJSON.eachValues`) — NOT the FROM-clause
/// table-valued `json_each` of RFC 0011, which this harness never touches.
@Suite("apple-docs main query parity (RFC 0010 §2)")
struct AppleDocsMainQueryTests {
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - The §2.2 / §2.3 query surface (string-built so each clause is explicit)

    /// The §2.3 projection — 24 columns in the exact fixed positional order the JS
    /// decoder reads, followed by `rank` (col 22) and `tier` (col 23). Two of the
    /// columns are the §2.3 `COALESCE(r.…, d.framework)` framework-fold pair.
    private static let projection = """
        d.key AS path, d.title, d.role, d.role_heading, d.abstract_text AS abstract,
        d.declaration_text AS declaration, d.platforms_json AS platforms,
        d.min_ios, d.min_macos, d.min_watchos, d.min_tvos, d.min_visionos,
        COALESCE(r.display_name, d.framework) AS framework,
        COALESCE(r.slug, d.framework) AS root_slug,
        d.source_type, d.source_metadata, d.url_depth, d.is_release_notes,
        d.is_deprecated, d.is_beta, d.kind AS doc_kind, d.language,
        bm25(documents_fts, 10.0, 5.0, 3.0, 2.0, 1.0) AS rank,
        CASE WHEN LOWER(d.title) = LOWER($raw) THEN 0
             WHEN LOWER(d.key) = LOWER($raw) THEN 0
             WHEN LOWER(d.title) LIKE LOWER($raw) || '%' THEN 1
             WHEN INSTR(LOWER(d.title), LOWER($raw)) > 0 THEN 2
             ELSE 3 END AS tier
        """

    /// The §2.2 skeleton with a pluggable `<extra filters>` slot and trailing
    /// `ORDER BY tier, rank LIMIT`. `documents_fts MATCH $query` drives the source.
    private static func mainQuery(extraFilters: String = "", limit: Int = 50) -> String {
        """
        SELECT \(projection)
        FROM documents_fts
        JOIN documents d ON documents_fts.rowid = d.id
        LEFT JOIN roots r ON r.slug = d.framework
        WHERE documents_fts MATCH $query
        \(extraFilters)
        ORDER BY tier, rank LIMIT \(limit)
        """
    }

    private let manifest = ImportManifest(ftsTables: [
        .init(
            name: "documents_fts",
            columns: ["title", "abstract", "declaration", "headings", "key"],
            tokenize: ["porter", "unicode61"],
            source: .init(
                table: "documents",
                columns: ["title", "abstract_text", "declaration_text", "headings", "key"]))
    ])

    // MARK: - Tests

    /// The bare §2.2 main query (no §2.4 filters): bm25(5-weight) + tier CASE +
    /// JOIN documents + LEFT JOIN roots + the 24-col projection + ORDER BY tier,rank.
    @Test func mainQueryNoFiltersMatchesSQLite() throws {
        try withImportedCorpus { db, src in
            for (query, raw) in Self.probes {
                try expectParity(
                    db, src, sql: Self.mainQuery(),
                    params: ["query": .text(query), "raw": .text(raw)],
                    label: "main(no-filter) query='\(query)' raw='\(raw)'")
            }
        }
    }

    /// §2.4 (1) `framework` (=). Bound to a framework present in the corpus.
    @Test func filterFrameworkEquality() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(extraFilters: "AND ($framework IS NULL OR d.framework = $framework)")
            for (query, raw) in Self.probes {
                // `framework` is the slug (apple-docs LEFT JOIN is `r.slug = d.framework`).
                for framework in [Value.null, .text("swiftui"), .text("uikit"), .text("metal")] {
                    try expectParity(
                        db, src, sql: sql,
                        params: ["query": .text(query), "raw": .text(raw), "framework": framework],
                        label: "framework=\(framework) query='\(query)'")
                }
            }
            // Selectivity guard: the filter must actually bite for a broad probe.
            let unfiltered = try adsqlRows(
                db, sql, ["query": .text("view"), "raw": .text("View"), "framework": .null]
            ).count
            let swiftuiOnly = try adsqlRows(
                db, sql, ["query": .text("view"), "raw": .text("View"), "framework": .text("swiftui")]
            ).count
            #expect(
                swiftuiOnly > 0 && swiftuiOnly < unfiltered,
                "framework filter not selective: \(swiftuiOnly) of \(unfiltered)")
        }
    }

    /// §2.4 (2) `source_type` (=).
    @Test func filterSourceTypeEquality() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(
                extraFilters: "AND ($source_type IS NULL OR d.source_type = $source_type)")
            for (query, raw) in Self.probes {
                for sourceType in [Value.null, .text("doc"), .text("wwdc")] {
                    try expectParity(
                        db, src, sql: sql,
                        params: ["query": .text(query), "raw": .text(raw), "source_type": sourceType],
                        label: "source_type=\(sourceType) query='\(query)'")
                }
            }
        }
    }

    /// §2.4 (3) `sources_json` — `d.source_type IN (SELECT value FROM
    /// json_each($sources_json))`, via ADSQL's self-contained `inJSONEach` node.
    @Test func filterSourcesJSONInList() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(
                extraFilters: """
                    AND ($sources_json IS NULL
                         OR d.source_type IN (SELECT value FROM json_each($sources_json)))
                    """)
            for (query, raw) in Self.probes {
                for sources in [Value.null, .text("[\"doc\"]"), .text("[\"doc\",\"wwdc\"]")] {
                    try expectParity(
                        db, src, sql: sql,
                        params: ["query": .text(query), "raw": .text(raw), "sources_json": sources],
                        label: "sources_json=\(sources) query='\(query)'")
                }
            }
        }
    }

    /// §2.4 (4) `kind` — LOWER-match over role_heading / kind / role.
    @Test func filterKind() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(
                extraFilters: """
                    AND ($kind IS NULL
                         OR LOWER(d.role_heading) = LOWER($kind)
                         OR LOWER(d.kind) = LOWER($kind)
                         OR LOWER(d.role) = LOWER($kind))
                    """)
            for (query, raw) in Self.probes {
                for kind in [Value.null, .text("symbol"), .text("article")] {
                    try expectParity(
                        db, src, sql: sql,
                        params: ["query": .text(query), "raw": .text(raw), "kind": kind],
                        label: "kind=\(kind) query='\(query)'")
                }
            }
        }
    }

    /// §2.4 (5) `language` (=/NULL/'both').
    @Test func filterLanguage() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(
                extraFilters: "AND ($language IS NULL OR $language = 'both' OR d.language = $language)")
            for (query, raw) in Self.probes {
                for language in [Value.null, .text("both"), .text("swift"), .text("occ")] {
                    try expectParity(
                        db, src, sql: sql,
                        params: ["query": .text(query), "raw": .text(raw), "language": language],
                        label: "language=\(language) query='\(query)'")
                }
            }
        }
    }

    /// §2.4 (6) `year` — `CAST(json_extract(source_metadata,'$.year') AS INTEGER)=$year`.
    @Test func filterYear() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(
                extraFilters: """
                    AND ($year IS NULL
                         OR CAST(json_extract(d.source_metadata, '$.year') AS INTEGER) = $year)
                    """)
            for (query, raw) in Self.probes {
                for year in [Value.null, .integer(2024), .integer(2023)] {
                    try expectParity(
                        db, src, sql: sql,
                        params: ["query": .text(query), "raw": .text(raw), "year": year],
                        label: "year=\(year) query='\(query)'")
                }
            }
        }
    }

    /// §2.4 (7) `track_like` — `LOWER(COALESCE(json_extract(source_metadata,
    /// '$.track'),'')) LIKE $track_like`.
    @Test func filterTrackLike() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(
                extraFilters: """
                    AND ($track_like IS NULL
                         OR LOWER(COALESCE(json_extract(d.source_metadata, '$.track'), '')) LIKE $track_like)
                    """)
            for (query, raw) in Self.probes {
                for track in [Value.null, .text("%swiftui%"), .text("graphics%")] {
                    try expectParity(
                        db, src, sql: sql,
                        params: ["query": .text(query), "raw": .text(raw), "track_like": track],
                        label: "track_like=\(track) query='\(query)'")
                }
            }
        }
    }

    /// §2.4 (8) `deprecated_mode` — include / exclude / only over `is_deprecated`.
    /// The JS binds this as a precomputed pair of guard ints; we mirror that shape
    /// (`$dep_exclude` filters out deprecated; `$dep_only` requires deprecated).
    @Test func filterDeprecatedMode() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(
                extraFilters: """
                    AND ($dep_exclude IS NULL OR d.is_deprecated = 0)
                    AND ($dep_only IS NULL OR d.is_deprecated = 1)
                    """)
            for (query, raw) in Self.probes {
                // include (both NULL), exclude (dep_exclude=1), only (dep_only=1).
                let modes: [(Value, Value)] = [(.null, .null), (.integer(1), .null), (.null, .integer(1))]
                for (exclude, only) in modes {
                    try expectParity(
                        db, src, sql: sql,
                        params: [
                            "query": .text(query), "raw": .text(raw),
                            "dep_exclude": exclude, "dep_only": only,
                        ],
                        label: "deprecated(exclude=\(exclude),only=\(only)) query='\(query)'")
                }
            }
        }
    }

    /// §2.4 (9–13) the 5× `min_*_num IS NULL OR min_*_num <= $min_*` platform ranges.
    @Test func filterMinPlatformRanges() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(
                extraFilters: """
                    AND ($min_ios IS NULL OR d.min_ios_num IS NULL OR d.min_ios_num <= $min_ios)
                    AND ($min_macos IS NULL OR d.min_macos_num IS NULL OR d.min_macos_num <= $min_macos)
                    AND ($min_watchos IS NULL OR d.min_watchos_num IS NULL OR d.min_watchos_num <= $min_watchos)
                    AND ($min_tvos IS NULL OR d.min_tvos_num IS NULL OR d.min_tvos_num <= $min_tvos)
                    AND ($min_visionos IS NULL OR d.min_visionos_num IS NULL OR d.min_visionos_num <= $min_visionos)
                    """)
            for (query, raw) in Self.probes {
                let bags: [[String: Value]] = [
                    [:],  // all NULL
                    ["min_ios": .integer(17)],
                    ["min_ios": .integer(26), "min_macos": .integer(15)],
                    ["min_visionos": .integer(2), "min_tvos": .integer(18), "min_watchos": .integer(11)],
                ]
                for bag in bags {
                    var params: [String: Value] = ["query": .text(query), "raw": .text(raw)]
                    for key in ["min_ios", "min_macos", "min_watchos", "min_tvos", "min_visionos"] {
                        params[key] = bag[key] ?? .null
                    }
                    try expectParity(
                        db, src, sql: sql, params: params,
                        label: "min_ranges=\(bag) query='\(query)'")
                }
            }
        }
    }

    /// All 13 filters bound at once with a representative non-NULL bag — the closest
    /// shape to a live `/search` request — plus the all-NULL passthrough.
    @Test func allFiltersTogether() throws {
        try withImportedCorpus { db, src in
            let sql = Self.mainQuery(
                extraFilters: """
                    AND ($framework IS NULL OR d.framework = $framework)
                    AND ($source_type IS NULL OR d.source_type = $source_type)
                    AND ($sources_json IS NULL
                         OR d.source_type IN (SELECT value FROM json_each($sources_json)))
                    AND ($kind IS NULL
                         OR LOWER(d.role_heading) = LOWER($kind)
                         OR LOWER(d.kind) = LOWER($kind)
                         OR LOWER(d.role) = LOWER($kind))
                    AND ($language IS NULL OR $language = 'both' OR d.language = $language)
                    AND ($year IS NULL
                         OR CAST(json_extract(d.source_metadata, '$.year') AS INTEGER) = $year)
                    AND ($track_like IS NULL
                         OR LOWER(COALESCE(json_extract(d.source_metadata, '$.track'), '')) LIKE $track_like)
                    AND ($dep_exclude IS NULL OR d.is_deprecated = 0)
                    AND ($dep_only IS NULL OR d.is_deprecated = 1)
                    AND ($min_ios IS NULL OR d.min_ios_num IS NULL OR d.min_ios_num <= $min_ios)
                    AND ($min_macos IS NULL OR d.min_macos_num IS NULL OR d.min_macos_num <= $min_macos)
                    AND ($min_watchos IS NULL OR d.min_watchos_num IS NULL OR d.min_watchos_num <= $min_watchos)
                    AND ($min_tvos IS NULL OR d.min_tvos_num IS NULL OR d.min_tvos_num <= $min_tvos)
                    AND ($min_visionos IS NULL OR d.min_visionos_num IS NULL OR d.min_visionos_num <= $min_visionos)
                    """)
            let allNull = Self.filterKeys.reduce(into: [String: Value]()) { $0[$1] = .null }
            let representative: [String: Value] = [
                "source_type": .text("doc"), "language": .text("both"),
                "dep_exclude": .integer(1), "min_ios": .integer(26),
            ]
            for (query, raw) in Self.probes {
                for overrides in [allNull, representative] {
                    var params = overrides
                    for key in Self.filterKeys where params[key] == nil { params[key] = .null }
                    params["query"] = .text(query)
                    params["raw"] = .text(raw)
                    try expectParity(
                        db, src, sql: sql, params: params,
                        label: "all-filters(\(overrides.keys.sorted())) query='\(query)'")
                }
            }
        }
    }

    /// Discrimination guard — proves the parity tests above are not vacuous: the
    /// "view"/"View" probe must span every tier (0/1/2/3), exercising each branch of
    /// the §2.2 tier CASE, and a `LEFT JOIN roots` result set must contain BOTH rows
    /// that hit a roots entry (COALESCE picks `r.display_name`) AND rows that miss it
    /// (COALESCE falls back to `d.framework`), so both COALESCE branches are pinned.
    ///
    /// (Tie coverage is also real: the "swiftui"/"data"/"render" probes each yield
    /// rows with identical `(tier, rank)` keys, so the full-row positional equality
    /// in `expectParity` additionally pins tie-ordering parity under `ORDER BY tier,
    /// rank` with no explicit rowid tiebreak — the F2 ascending-rowid tie-break holds
    /// through the JOIN + multi-key sort.)
    @Test func probesExerciseEveryTierAndBothCoalesceBranches() throws {
        try withImportedCorpus { db, src in
            // Tier spread: the broad "view" probe hits all four tiers.
            let rows = try adsqlRows(
                db, Self.mainQuery(), ["query": .text("view"), "raw": .text("View")])
            var tiers = Set<Int64>()
            for row in rows { if case .integer(let t) = row[23] { tiers.insert(t) } }
            #expect(tiers == [0, 1, 2, 3], "tier CASE under-exercised: only tiers \(tiers.sorted())")

            // COALESCE fallback both ways: some rows hit roots (slug present),
            // some miss (Metal/CoreData/etc. → NULL root). root_slug is col 13.
            let dataRows = try adsqlRows(
                db, Self.mainQuery(), ["query": .text("data"), "raw": .text("Data")])
            let rootHit = try adsqlRows(
                db,
                """
                SELECT COUNT(*) FROM documents_fts JOIN documents d ON documents_fts.rowid = d.id
                LEFT JOIN roots r ON r.slug = d.framework
                WHERE documents_fts MATCH $query AND r.slug IS NOT NULL
                """, ["query": .text("data")])
            let rootMiss = try adsqlRows(
                db,
                """
                SELECT COUNT(*) FROM documents_fts JOIN documents d ON documents_fts.rowid = d.id
                LEFT JOIN roots r ON r.slug = d.framework
                WHERE documents_fts MATCH $query AND r.slug IS NULL
                """, ["query": .text("data")])
            #expect(!dataRows.isEmpty, "the 'data' probe returned no rows")
            if case .integer(let hit) = rootHit.first?[0] { #expect(hit > 0, "no LEFT JOIN roots hit") }
            if case .integer(let miss) = rootMiss.first?[0] {
                #expect(miss > 0, "no COALESCE fallback (every framework had a roots entry)")
            }
            _ = src
        }
    }

    // MARK: - Probes + filter keys

    /// (`$query`, `$raw`) pairs chosen to exercise every tier:
    ///   - "swiftui"/"SwiftUI" — exact title-prefix + framework anchor (tiers 0/1/2).
    ///   - "view"/"View"       — broad substring across many titles (tier 1/2/3).
    ///   - "async"/"AsyncImage"— prefix + substring against the seeded exact titles.
    ///   - "render"/"render"   — body/abstract-only porter stem (tier 3, rank spread).
    private static let probes: [(String, String)] = [
        ("swiftui", "SwiftUI"),
        ("view", "View"),
        ("async", "AsyncSequence"),
        ("data", "Data"),
        ("render", "render"),
    ]

    /// The 13 filter param names (NULL-guarded), plus the deprecated-mode pair split.
    private static let filterKeys = [
        "framework", "source_type", "sources_json", "kind", "language", "year",
        "track_like", "dep_exclude", "dep_only", "min_ios", "min_macos",
        "min_watchos", "min_tvos", "min_visionos",
    ]

    // MARK: - Corpus

    /// Builds the apple-docs-shaped SQLite fixture, imports it into a fresh ADSQL
    /// database, and hands both to `body`. The source SQLite handle stays open as
    /// the diff oracle.
    private func withImportedCorpus(
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
    /// ~30 deterministic, varied rows so the tiers and every filter bite. The FTS
    /// table is populated from `documents` exactly as the importer reconstructs it.
    private func buildFixture(_ db: OpaquePointer?) throws {
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

        for doc in Self.seedRows() {
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

    // MARK: - Parity diff

    /// Runs `sql` with `params` against ADSQL and the SQLite oracle and asserts the
    /// result rows are identical — same row count, same order, each cell equal —
    /// with the bm25 `rank` column (index 22) compared within 1e-9 relative and the
    /// integer `tier` (index 23) exact. Every other cell must be byte-identical.
    private func expectParity(
        _ db: Database, _ src: OpaquePointer?, sql: String, params: [String: Value], label: String
    ) throws {
        let ours = try adsqlRows(db, sql, params)
        let theirs = sqliteRows(src, sql, params)
        #expect(ours.count == theirs.count, "\(label): row count adsql \(ours.count) vs sqlite \(theirs.count)")
        for (rowIndex, (ourRow, theirRow)) in zip(ours, theirs).enumerated() {
            #expect(
                ourRow.count == theirRow.count,
                "\(label): row \(rowIndex) width adsql \(ourRow.count) vs sqlite \(theirRow.count)")
            for col in 0..<Swift.min(ourRow.count, theirRow.count) {
                if col == Self.rankColumn {
                    let a = ourRow[col].doubleValue ?? .nan
                    let b = theirRow[col].doubleValue ?? .nan
                    #expect(
                        abs(a - b) <= 1e-9 * Swift.max(abs(b), 1),
                        "\(label): row \(rowIndex) rank adsql \(a) vs sqlite \(b)")
                } else {
                    #expect(
                        ourRow[col] == theirRow[col],
                        "\(label): row \(rowIndex) col \(col) adsql \(ourRow[col]) vs sqlite \(theirRow[col])")
                }
            }
        }
    }

    private static let rankColumn = 22  // 0-based: the bm25 `rank` projection column

    private func adsqlRows(
        _ db: Database, _ sql: String, _ params: [String: Value]
    ) throws -> [[Value]] {
        try db.prepare(sql).all(params).map(\.values)
    }

    /// The SQLite oracle: prepare `sql`, bind every `$name` param by index (resolved
    /// via `sqlite3_bind_parameter_index`), step, and read each cell into a `Value`
    /// with the same storage-class dispatch the importer uses.
    private func sqliteRows(
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
                _ = b.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), transient) }
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

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        let detail = message.map { String(cString: $0) } ?? ""
        sqlite3_free(message)
        try #require(rc == SQLITE_OK, "exec failed (\(rc)): \(detail)\nSQL: \(sql)")
    }
}

extension Value {
    /// The numeric payload as a Double (for the bm25 rank tolerance compare). nil
    /// for non-numeric values.
    fileprivate var doubleValue: Double? {
        switch self {
        case .real(let d): return d
        case .integer(let v): return Double(v)
        default: return nil
        }
    }
}

// MARK: - Seed corpus (apple-docs-shaped, hand-tuned for tier + filter coverage)

extension AppleDocsMainQueryTests {
    /// One `documents` row, with the §2.1 read columns. SQL-literal escaping is
    /// limited to single quotes (the only quote the seeds use); the corpus is fixed
    /// so this is sufficient and keeps the fixture Foundation-free.
    fileprivate struct AppleDoc {
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

    /// ~30 deterministic rows tuned so every tier and every filter discriminates:
    ///   - exact-title matches for the probe raws ("SwiftUI", "View", "Data",
    ///     "AsyncSequence") → tier 0; title-prefix → tier 1; title-substring →
    ///     tier 2; abstract/body-only → tier 3.
    ///   - frameworks both in `roots` (SwiftUI/UIKit/Foundation/Combine → LEFT JOIN
    ///     hit) and absent (Metal/CoreData → COALESCE fallback, r.* NULL).
    ///   - source_type ∈ {doc, wwdc, sample}; source_metadata JSON with year/track;
    ///     is_deprecated / is_beta toggled; language ∈ {swift, occ, both}; varied
    ///     min_*_num (incl. NULLs) and url_depth.
    fileprivate static func seedRows() -> [AppleDoc] {
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

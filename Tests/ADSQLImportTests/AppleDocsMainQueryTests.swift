import ADSQL
import ADSQLImport
import ADSQLTestSupport
import CSQLite
import Testing

/// M8 (RFC 0010 §2) — apple-docs "main" search-query byte-parity verification.
///
/// This is a VERIFY-AND-REPORT harness, not a feature build: it constructs a small
/// apple-docs-shaped SQLite corpus (`AppleDocsFixture`), imports it into ADSQL via
/// `db.importSQLite`, and runs the §2.2 hot-path query (5-weight `bm25` + `tier`
/// CASE + `JOIN documents` + `LEFT JOIN roots` + the §2.3 24-column projection +
/// `ORDER BY tier, rank LIMIT`) against BOTH the source SQLite (the oracle) and
/// ADSQL, then diffs the result rows for value + order parity (with `bm25` rank
/// compared within 1e-9 relative).
///
/// Each of the §2.4 filter predicates is then layered on incrementally and diffed,
/// so the readiness of every clause is independently pinned. The `inJSONEach`
/// (`d.source_type IN (SELECT value FROM json_each($sources_json))`) clause is
/// exercised via ADSQL's *self-contained* `inJSONEach` AST node (parsed from the
/// contracted shape, evaluated by `SQLJSON.eachValues`) — NOT the FROM-clause
/// table-valued `json_each` of RFC 0011, which this harness never touches.
///
/// The shared corpus, manifest, import harness, probes, and the SQLite oracle live
/// in `AppleDocsFixture` (also used by the M8 INT `SearchPagesFramedTests`).
@Suite("apple-docs main query parity (RFC 0010 §2)")
struct AppleDocsMainQueryTests {
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

    private static var probes: [(String, String)] { AppleDocsFixture.probes }
    private static var filterKeys: [String] { AppleDocsFixture.filterKeys }

    // MARK: - Tests

    /// The bare §2.2 main query (no §2.4 filters): bm25(5-weight) + tier CASE +
    /// JOIN documents + LEFT JOIN roots + the 24-col projection + ORDER BY tier,rank.
    @Test func mainQueryNoFiltersMatchesSQLite() throws {
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
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
            let unfiltered = try AppleDocsFixture.adsqlRows(
                db, sql, ["query": .text("view"), "raw": .text("View"), "framework": .null]
            ).count
            let swiftuiOnly = try AppleDocsFixture.adsqlRows(
                db, sql, ["query": .text("view"), "raw": .text("View"), "framework": .text("swiftui")]
            ).count
            #expect(
                swiftuiOnly > 0 && swiftuiOnly < unfiltered,
                "framework filter not selective: \(swiftuiOnly) of \(unfiltered)")
        }
    }

    /// §2.4 (2) `source_type` (=).
    @Test func filterSourceTypeEquality() throws {
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
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
        try AppleDocsFixture.withImportedCorpus { db, src in
            // Tier spread: the broad "view" probe hits all four tiers.
            let rows = try AppleDocsFixture.adsqlRows(
                db, Self.mainQuery(), ["query": .text("view"), "raw": .text("View")])
            var tiers = Set<Int64>()
            for row in rows { if case .integer(let t) = row[23] { tiers.insert(t) } }
            #expect(tiers == [0, 1, 2, 3], "tier CASE under-exercised: only tiers \(tiers.sorted())")

            // COALESCE fallback both ways: some rows hit roots (slug present),
            // some miss (Metal/CoreData/etc. → NULL root). root_slug is col 13.
            let dataRows = try AppleDocsFixture.adsqlRows(
                db, Self.mainQuery(), ["query": .text("data"), "raw": .text("Data")])
            let rootHit = try AppleDocsFixture.adsqlRows(
                db,
                """
                SELECT COUNT(*) FROM documents_fts JOIN documents d ON documents_fts.rowid = d.id
                LEFT JOIN roots r ON r.slug = d.framework
                WHERE documents_fts MATCH $query AND r.slug IS NOT NULL
                """, ["query": .text("data")])
            let rootMiss = try AppleDocsFixture.adsqlRows(
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

    // MARK: - Parity diff

    /// Runs `sql` with `params` against ADSQL and the SQLite oracle and asserts the
    /// result rows are identical — same row count, same order, each cell equal —
    /// with the bm25 `rank` column (index 22) compared within 1e-9 relative and the
    /// integer `tier` (index 23) exact. Every other cell must be byte-identical.
    private func expectParity(
        _ db: Database, _ src: OpaquePointer?, sql: String, params: [String: Value], label: String
    ) throws {
        let ours = try AppleDocsFixture.adsqlRows(db, sql, params)
        let theirs = AppleDocsFixture.sqliteRows(src, sql, params)
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
}

import ADSQL
import ADSQLImport
import ADSQLSearch
import ADSQLTestSupport
import CSQLite
import Testing

/// M8 F6 (RFC 0010 §2.2-2.4, "F6" build-time denormalization) — the CORRECTNESS
/// proof that the denormalized read query is a FAITHFUL rewrite of the §2.2 form.
///
/// F6 trades per-match string/JSON work for cheap comparisons against precomputed
/// columns: the tier `CASE` reads `title_lc`/`key_lc` vs a single bound `$raw_lc`
/// (instead of `LOWER(d.title)`/`LOWER(d.key)`/`LOWER($raw)` per row), the `year`
/// filter reads `year_num` (instead of `CAST(json_extract(…,'$.year') AS INTEGER)`),
/// the `track_like` filter reads `track_lc` (instead of
/// `LOWER(COALESCE(json_extract(…,'$.track'),''))`), and the framework projection
/// reads `root_display`/`root_slug` (instead of `COALESCE(r.…, d.framework)` over a
/// `LEFT JOIN roots`, which the denorm query DROPS).
///
/// This suite asserts ``SearchQuery/denormSQL`` returns BYTE-IDENTICAL rows + order
/// to the ORIGINAL ``SearchQuery/sql`` on the SAME fixture — BOTH run on ADSQL (this
/// is not a SQLite compare; the SQLite-oracle parity is `AppleDocsMainQueryTests` +
/// `SearchPagesFramedTests`). Every cell, including the bm25 `rank`, must match
/// within 1e-9 relative (the two queries score the identical match set, so the rank
/// is in fact bit-identical — but the 1e-9 tolerance mirrors the oracle harnesses
/// and guards against any FTS re-evaluation order effect). It runs the full probe
/// set plus a representative spread of filter bags (no-filter, framework=, year,
/// track, deprecated, and the all-at-once representative bag).
///
/// Because the fixture's denorm columns are computed by SQLite's OWN
/// `LOWER`/`CAST`/`json_extract`/`COALESCE` (see `AppleDocsFixture.buildFixture`)
/// and then imported into ADSQL, byte-equality here transitively proves the denorm
/// columns themselves are exact — the read query is reading provably-correct folds.
@Suite("apple-docs F6 denorm-vs-original equivalence (RFC 0010 §2.2-2.4)")
struct SearchDenormEquivalenceTests {
    private static var probes: [(String, String)] { AppleDocsFixture.probes }

    /// The no-filter probe set — the bare hot path through both query forms.
    @Test func noFilterDenormEqualsOriginal() throws {
        try AppleDocsFixture.withImportedCorpus { db, _ in
            for (query, raw) in Self.probes {
                let params = SearchPagesParams(query: query, raw: raw, limit: 50)
                try expectDenormEquivalence(db, params, label: "no-filter query='\(query)'")
            }
        }
    }

    /// `framework` (=) — exercises the `root_display`/`root_slug` projection fold
    /// (the dropped `LEFT JOIN roots`) under a biting framework filter, across a
    /// roots-present slug and a roots-absent one (`Metal` ⇒ COALESCE fallback).
    @Test func frameworkFilterDenormEqualsOriginal() throws {
        try AppleDocsFixture.withImportedCorpus { db, _ in
            for (query, raw) in Self.probes {
                for framework in [nil, "swiftui", "uikit", "Metal", "CoreData"] {
                    let params = SearchPagesParams(
                        query: query, raw: raw, limit: 50, framework: framework)
                    try expectDenormEquivalence(
                        db, params, label: "framework=\(framework ?? "nil") query='\(query)'")
                }
            }
        }
    }

    /// `year` — exercises the `year_num` fold (vs `CAST(json_extract … AS INTEGER)`),
    /// including a year present in the corpus, one absent, and the nil passthrough.
    @Test func yearFilterDenormEqualsOriginal() throws {
        try AppleDocsFixture.withImportedCorpus { db, _ in
            for (query, raw) in Self.probes {
                for year in [nil, Int64(2024), 2023, 2019, 1999] {
                    let params = SearchPagesParams(query: query, raw: raw, limit: 50, year: year)
                    try expectDenormEquivalence(
                        db, params, label: "year=\(year.map(String.init) ?? "nil") query='\(query)'")
                }
            }
        }
    }

    /// `track_like` — exercises the `track_lc` fold (vs `LOWER(COALESCE(json_extract
    /// … '$.track'),''))`), including a prefix LIKE, a substring LIKE, a pattern that
    /// only the COALESCE-empty rows could match, and the nil passthrough.
    @Test func trackFilterDenormEqualsOriginal() throws {
        try AppleDocsFixture.withImportedCorpus { db, _ in
            for (query, raw) in Self.probes {
                for track in [nil, "%swiftui%", "graphics%", "swift concurrency", "%"] {
                    let params = SearchPagesParams(
                        query: query, raw: raw, limit: 50, trackLike: track)
                    try expectDenormEquivalence(
                        db, params, label: "track_like=\(track ?? "nil") query='\(query)'")
                }
            }
        }
    }

    /// `deprecated_mode` — include/exclude/only over `is_deprecated` (a base-column
    /// filter, unchanged by F6) through both forms, proving the denorm rewrite did
    /// not perturb the untouched predicates.
    @Test func deprecatedModeDenormEqualsOriginal() throws {
        try AppleDocsFixture.withImportedCorpus { db, _ in
            for (query, raw) in Self.probes {
                for mode in ["include", "exclude", "only"] {
                    let params = SearchPagesParams(
                        query: query, raw: raw, limit: 50, deprecatedMode: mode)
                    try expectDenormEquivalence(
                        db, params, label: "deprecated=\(mode) query='\(query)'")
                }
            }
        }
    }

    /// The representative multi-filter bag (the closest shape to a live `/search`
    /// request) — source_type + language='both' + deprecated exclude + a min-iOS
    /// range — plus a year+track combo that hits BOTH denorm JSON folds at once.
    @Test func representativeBagsDenormEqualsOriginal() throws {
        try AppleDocsFixture.withImportedCorpus { db, _ in
            for (query, raw) in Self.probes {
                let representative = SearchPagesParams(
                    query: query, raw: raw, limit: 50, sourceType: "doc", language: "both",
                    deprecatedMode: "exclude", minIOS: 26)
                try expectDenormEquivalence(
                    db, representative, label: "representative query='\(query)'")

                let jsonBoth = SearchPagesParams(
                    query: query, raw: raw, limit: 50, year: 2024, trackLike: "%essentials%")
                try expectDenormEquivalence(
                    db, jsonBoth, label: "year+track query='\(query)'")
            }
        }
    }

    /// Discrimination guard — proves the equivalence tests are not vacuous: at least
    /// one probe must span every tier (0/1/2/3) through the DENORM query (so the
    /// rewritten tier `CASE` over `title_lc`/`key_lc` is fully exercised), and the
    /// denorm projection must contain BOTH a roots-hit row (`root_display` differs
    /// from `root_slug`, e.g. "SwiftUI" vs "swiftui") AND a roots-miss row
    /// (`root_display` == framework, the COALESCE fallback).
    @Test func denormProbesExerciseEveryTierAndBothCoalesceBranches() throws {
        try AppleDocsFixture.withImportedCorpus { db, _ in
            let params = SearchPagesParams(query: "view", raw: "View", limit: 50)
            let rows = try AppleDocsFixture.adsqlRows(
                db, SearchQuery.denormSQL, SearchQuery.denormBindings(for: params))
            var tiers = Set<Int64>()
            for row in rows { if case .integer(let t) = row[23] { tiers.insert(t) } }
            #expect(
                tiers == [0, 1, 2, 3],
                "denorm tier CASE under-exercised: only tiers \(tiers.sorted())")

            // root_display (col 12) vs root_slug (col 13): a roots HIT has them differ
            // (display name vs slug), a MISS has them equal (both == framework).
            var sawHit = false
            var sawMiss = false
            for row in rows {
                guard case .text(let display) = row[12], case .text(let slug) = row[13] else { continue }
                if display != slug { sawHit = true } else { sawMiss = true }
            }
            #expect(sawHit, "no roots-hit row (root_display never differed from root_slug)")
            #expect(sawMiss, "no roots-miss row (COALESCE fallback never taken)")
        }
    }

    // MARK: - The denorm-vs-original diff (both on ADSQL)

    /// Runs ``SearchQuery/sql`` (original §2.2) and ``SearchQuery/denormSQL`` (F6) for
    /// `params` against the SAME ADSQL database and asserts row-for-row, cell-for-cell
    /// equality: same row count, same order, every non-rank cell byte-identical, and
    /// the bm25 `rank` (col 22) within 1e-9 relative. This is the F6 faithfulness
    /// proof.
    private func expectDenormEquivalence(
        _ db: Database, _ params: SearchPagesParams, label: String
    ) throws {
        let original = try AppleDocsFixture.adsqlRows(
            db, SearchQuery.sql, SearchQuery.bindings(for: params))
        let denorm = try AppleDocsFixture.adsqlRows(
            db, SearchQuery.denormSQL, SearchQuery.denormBindings(for: params))

        #expect(
            original.count == denorm.count,
            "\(label): row count original \(original.count) vs denorm \(denorm.count)")
        for (rowIndex, (originalRow, denormRow)) in zip(original, denorm).enumerated() {
            #expect(
                originalRow.count == denormRow.count,
                "\(label): row \(rowIndex) width original \(originalRow.count) vs denorm \(denormRow.count)")
            for col in 0..<Swift.min(originalRow.count, denormRow.count) {
                if col == Self.rankColumn {
                    let a = originalRow[col].doubleValue ?? .nan
                    let b = denormRow[col].doubleValue ?? .nan
                    #expect(
                        abs(a - b) <= 1e-9 * Swift.max(abs(b), 1),
                        "\(label): row \(rowIndex) rank original \(a) vs denorm \(b)")
                } else {
                    #expect(
                        originalRow[col] == denormRow[col],
                        "\(label): row \(rowIndex) col \(col) original \(originalRow[col]) vs denorm \(denormRow[col])")
                }
            }
        }
    }

    private static let rankColumn = 22  // 0-based: the bm25 `rank` projection column
}

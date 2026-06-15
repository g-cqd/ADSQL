public import ADSQL

/// The §2.2 "main" search query — the apple-docs hot path — as a value type that
/// owns the SQL text and the per-request bind bag. The query string is built once
/// here (lifted out of `AppleDocsMainQueryTests` — this is the real implementation
/// now) so the projection (§2.3), the tier `CASE`, the `JOIN documents` /
/// `LEFT JOIN roots`, and the 13 NULL-guarded §2.4 filters are pinned in one place.
///
/// The canonical `sql` text and `bindings(for:)` bag are `public` so the SQLite
/// parity oracle can run the IDENTICAL statement with the IDENTICAL params.
public enum SearchQuery {
    /// The §2.3 projection — 24 columns in the exact fixed positional order the JS
    /// decoder reads, ending with `rank` (col 22, 0-based) and `tier` (col 23).
    /// Two columns are the §2.3 `COALESCE(r.…, d.framework)` framework-fold pair.
    /// `bm25` weights are `(10, 5, 3, 2, 1)` over `(title, abstract, declaration,
    /// headings, key)`.
    public static let projection = """
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

    /// The number of columns the §2.3 projection emits (the framed `colCount`).
    public static let columnCount = 24

    /// The 13 §2.4 filter predicates, each NULL-guarded so a `nil`-bound param is a
    /// passthrough (`$x IS NULL OR <pred>`), exactly as apple-docs binds them. The
    /// `deprecated_mode` string is lowered into the `$dep_exclude` / `$dep_only`
    /// guard pair (`include` ⇒ both NULL). `sources_json` uses the contracted
    /// `IN (SELECT value FROM json_each(...))` shape ADSQL evaluates self-contained
    /// (its `inJSONEach` node), NOT the FROM-clause table-valued `json_each`.
    public static let filters = """
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
        """

    /// The full §2.2 statement: the §2.3 projection over `documents_fts` joined to
    /// `documents` (and the `roots` LEFT JOIN), `WHERE documents_fts MATCH $query`
    /// plus the §2.4 filters, `ORDER BY tier, rank LIMIT $limit`. `$limit` is bound
    /// (not interpolated) so the statement text is constant across requests and the
    /// prepared plan is reused.
    public static let sql = """
        SELECT \(projection)
        FROM documents_fts
        JOIN documents d ON documents_fts.rowid = d.id
        LEFT JOIN roots r ON r.slug = d.framework
        WHERE documents_fts MATCH $query
        \(filters)
        ORDER BY tier, rank LIMIT $limit
        """

    /// Builds the §2.5 named-parameter bind bag from a request. Every param the
    /// statement references is supplied (NULL when the filter is a passthrough),
    /// and `deprecated_mode` is lowered to the `$dep_exclude` / `$dep_only` guard
    /// pair: `exclude` ⇒ `dep_exclude = 1` (drop deprecated), `only` ⇒
    /// `dep_only = 1` (require deprecated), `include` (and anything else / nil) ⇒
    /// both NULL (no filter).
    public static func bindings(for params: SearchPagesParams) -> [String: Value] {
        let (depExclude, depOnly) = depGuards(params.deprecatedMode)
        return [
            "query": .text(params.query),
            "raw": .text(params.raw),
            "limit": .integer(params.limit),
            "framework": optionalText(params.framework),
            "source_type": optionalText(params.sourceType),
            "sources_json": optionalText(params.sourcesJSON),
            "kind": optionalText(params.kind),
            "language": optionalText(params.language),
            "year": optionalInt(params.year),
            "track_like": optionalText(params.trackLike),
            "dep_exclude": depExclude,
            "dep_only": depOnly,
            "min_ios": optionalInt(params.minIOS),
            "min_macos": optionalInt(params.minMacOS),
            "min_watchos": optionalInt(params.minWatchOS),
            "min_tvos": optionalInt(params.minTVOS),
            "min_visionos": optionalInt(params.minVisionOS),
        ]
    }

    /// `include`/nil → (NULL, NULL); `exclude` → (1, NULL); `only` → (NULL, 1).
    private static func depGuards(_ mode: String?) -> (exclude: Value, only: Value) {
        switch mode {
        case "exclude": return (.integer(1), .null)
        case "only": return (.null, .integer(1))
        default: return (.null, .null)  // "include" (default) and any unknown ⇒ no filter
        }
    }

    private static func optionalText(_ value: String?) -> Value {
        value.map(Value.text) ?? .null
    }

    private static func optionalInt(_ value: Int64?) -> Value {
        value.map(Value.integer) ?? .null
    }
}

extension Database {
    /// Runs the apple-docs §2.2 main search query for `params` and frames the
    /// result rows into the RFC 0010 §2.5 response bytes — the Swift body of the
    /// frozen `ad_storage_search_pages` ABI (the C `@_cdecl` export lands LATER, in
    /// apple-docs; see `ResponseFraming` for the wire layout).
    ///
    /// Correctness-first per RFC 0010 ("the prototype may use the existing `.all()`
    /// path + manual framing; F5/A2–A4 optimize later"): it binds the §2.4 filter
    /// bag (each `nil` filter a passthrough), executes via `prepare(sql).all(...)`,
    /// and hand-encodes the `[u32 colCount][u32 rowCount]` header + per-cell
    /// `[u8 tag][payload]` body. The column order is the fixed §2.3 projection.
    public func searchPagesFramed(_ params: SearchPagesParams) throws(DBError) -> [UInt8] {
        let rows = try prepare(SearchQuery.sql).all(SearchQuery.bindings(for: params)).map(\.values)
        return ResponseFraming.frame(rows: rows, columnCount: SearchQuery.columnCount)
    }
}

/// Free-function form of ``Database/searchPagesFramed(_:)`` matching the task's
/// requested signature `searchPagesFramed(_ db:_ params:)`. Delegates to the
/// method so there is a single implementation.
public func searchPagesFramed(
    _ db: Database, _ params: SearchPagesParams
) throws(DBError) -> [UInt8] {
    try db.searchPagesFramed(params)
}

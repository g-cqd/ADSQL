import ADSQL
import ADSQLSearch
import CSQLite

/// Deterministic, apple-docs-shaped corpus for the `search` scenario (RFC 0010
/// §1/§2). Self-contained in ADSQLBench — the bench target cannot import the
/// test-support `AppleDocsCorpus` (dependency constraint), so this is an
/// independent generator of the SAME shape: the §2.1 read schema (`documents` +
/// `roots` + `documents_fts`) seeded from a fixed-seed SplitMix64 stream over a
/// realistic API-like vocabulary (framework names, symbol-ish titles, doc prose).
///
/// A fresh `Generator()` replays byte-identical rows on every run and machine, and
/// both engines build from their own fresh stream — so ADSQL and SQLite index
/// IDENTICAL data and the latency/scaling compare is fair. Every §2.1 column the
/// read path touches is populated (the 24-col projection reads real bytes; the 13
/// filters discriminate): wide TEXT abstract/declaration/metadata (the A4 per-row
/// cost), `framework` both present and absent in `roots`, varied `source_type`,
/// `source_metadata` JSON with `$.year`/`$.track`, toggled deprecated/beta, mixed
/// `language`, and `min_*_num` platform ints (some NULL).
enum SearchCorpus {
    // MARK: - Schema (§2.1 read schema)

    /// `roots` — the framework LEFT JOIN. Covers MOST framework slugs (LEFT JOIN
    /// hits → `COALESCE` takes `display_name`) and deliberately omits a few (so the
    /// JOIN misses and `COALESCE` falls back to `d.framework`).
    static let roots: [(slug: String, displayName: String)] = [
        ("swiftui", "SwiftUI"), ("uikit", "UIKit"), ("appkit", "AppKit"),
        ("foundation", "Foundation"), ("combine", "Combine"), ("coredata", "Core Data"),
        ("metal", "Metal"), ("coreml", "Core ML"), ("cloudkit", "CloudKit"),
        ("avfoundation", "AVFoundation"), ("mapkit", "MapKit"), ("widgetkit", "WidgetKit"),
        ("swiftdata", "SwiftData"), ("observation", "Observation"),
        // NOTE: storekit, coregraphics, vision, arkit, realitykit, corelocation are
        // intentionally NOT in roots — their docs exercise the COALESCE fallback.
    ]

    /// The `roots` row whose `slug` matches `framework` (the LEFT JOIN
    /// `r.slug = d.framework`), or `nil` when no roots row matches (the COALESCE
    /// fallback) — the input to the F6 `root_display` / `root_slug` fold.
    static func rootEntry(_ framework: String) -> (slug: String, displayName: String)? {
        roots.first { $0.slug == framework }
    }

    /// The full §2.1 `documents` columns the read path reads (TEXT `min_*` mirrors
    /// plus the INTEGER `min_*_num` filter columns), `roots`, and the porter
    /// `documents_fts`. Built directly via ADSQL DDL.
    static let adsqlDDL = [
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
          kind TEXT, language TEXT, url_depth INTEGER,
          title_lc TEXT, key_lc TEXT, year_num INTEGER, track_lc TEXT,
          root_display TEXT, root_slug TEXT)
        """,
        "CREATE TABLE roots(slug TEXT PRIMARY KEY, display_name TEXT)",
        """
        CREATE VIRTUAL TABLE documents_fts USING fts5(
          title, abstract, declaration, headings, key, tokenize='porter unicode61')
        """,
    ]

    /// Identical schema for SQLite (only the FTS5 DDL spelling is shared; SQLite
    /// parses the same text).
    static let sqliteDDL = adsqlDDL

    /// The 34 §2.1 `documents` columns, in the fixed bind order both engines use —
    /// the 28 base columns plus the 6 F6 denormalized columns (`title_lc`, `key_lc`,
    /// `year_num`, `track_lc`, `root_display`, `root_slug`) the denorm query reads.
    private static let insertColumns = """
        id, key, title, role, role_heading, abstract_text, declaration_text, headings,
        platforms_json, min_ios_num, min_macos_num, min_watchos_num, min_tvos_num,
        min_visionos_num, min_ios, min_macos, min_watchos, min_tvos, min_visionos,
        framework, source_type, source_metadata, is_deprecated, is_beta,
        is_release_notes, kind, language, url_depth,
        title_lc, key_lc, year_num, track_lc, root_display, root_slug
        """

    /// The SQLite build INSERT — 34 numbered `?N` binds (SQLite's positional form).
    static let sqliteInsertSQL = """
        INSERT INTO documents(\(insertColumns))
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
          ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28,
          ?29, ?30, ?31, ?32, ?33, ?34)
        """

    /// The ADSQL build INSERT — 34 bare `?` binds (ADSQL numbers `?` 1-based by
    /// appearance; it does not accept the `?N` numbered form).
    static let adsqlInsertSQL = """
        INSERT INTO documents(\(insertColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
          ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
          ?, ?, ?, ?, ?, ?)
        """

    /// Every `$name` the §2.2 statement (`SearchQuery.sql`) references — so the
    /// SQLite reader resolves each bind index once at prepare. Mirrors the keys
    /// `SearchQuery.bindings(for:)` produces.
    static let paramNames = [
        "query", "raw", "limit", "framework", "source_type", "sources_json", "kind",
        "language", "year", "track_like", "dep_exclude", "dep_only", "min_ios",
        "min_macos", "min_watchos", "min_tvos", "min_visionos",
    ]

    // MARK: - Vocabulary (realistic API-like terms)

    /// Framework slugs (lowercased — matches `roots.slug` / `d.framework`). The
    /// first 14 are in `roots`; the last 6 are not (COALESCE fallback).
    static let frameworks = [
        "swiftui", "uikit", "appkit", "foundation", "combine", "coredata",
        "metal", "coreml", "cloudkit", "avfoundation", "mapkit", "widgetkit",
        "swiftdata", "observation", "storekit", "coregraphics", "vision",
        "arkit", "realitykit", "corelocation",
    ]
    /// Symbol-name stems — the leading noun of an API type.
    static let typeStems = [
        "Async", "Navigation", "Scroll", "Stack", "Grid", "List", "Text",
        "Image", "Button", "Toggle", "Picker", "Gesture", "Animation",
        "Layout", "Render", "Query", "Model", "Store", "Session", "Stream",
        "Buffer", "Texture", "Pipeline", "Descriptor", "Coordinate", "Fetch",
        "Persistent", "Observable", "Subscription", "Publisher",
    ]
    /// Symbol-name roles — the trailing noun (also reused as the `role` value).
    static let typeRoles = [
        "View", "Controller", "Manager", "Provider", "Builder", "Context",
        "Configuration", "Delegate", "Coordinator", "Renderer", "Reader",
        "Writer", "Cache", "Registry", "Resolver", "Container", "Sequence",
    ]
    static let proseVerbs = [
        "renders", "configures", "manages", "observes", "encodes", "decodes",
        "schedules", "animates", "loads", "caches", "fetches", "presents",
        "computes", "transforms", "synchronizes", "validates", "resolves",
    ]
    static let proseNouns = [
        "view", "value", "model", "context", "buffer", "texture", "request",
        "response", "gesture", "layout", "pipeline", "snapshot", "transaction",
        "subscription", "coordinate", "descriptor", "hierarchy", "data", "state",
    ]
    static let proseAdjectives = [
        "structured", "concurrent", "declarative", "immutable", "lazy", "shared",
        "observable", "asynchronous", "composable", "reusable", "deterministic",
    ]
    static let headingWords = [
        "Overview", "Topics", "Declaration", "Discussion", "Parameters",
        "Return Value", "See Also", "Mentioned in", "Availability", "Conforms To",
    ]
    static let sourceTypes = ["doc", "doc", "doc", "wwdc", "sample"]  // doc-weighted
    static let languages = ["swift", "swift", "occ", "both"]  // swift-weighted
    static let tracks = [
        "SwiftUI Essentials", "Graphics and Drawing", "Swift Concurrency",
        "App Frameworks", "Developer Tools", "Machine Learning",
    ]
    static let kinds = ["symbol", "symbol", "article", "collection", "sample"]

    // MARK: - Generator

    /// One generated `documents` row, all §2.1 read columns populated.
    struct Document {
        var id: Int64
        var key: String
        var title: String
        var role: String
        var roleHeading: String
        var abstract: String
        var declaration: String
        var headings: String
        var platformsJSON: String
        var minIOSNum: Int64?
        var minMacOSNum: Int64?
        var minWatchOSNum: Int64?
        var minTVOSNum: Int64?
        var minVisionOSNum: Int64?
        var minIOS: String
        var minMacOS: String
        var minWatchOS: String
        var minTVOS: String
        var minVisionOS: String
        var framework: String
        var sourceType: String
        var sourceMetadata: String
        var isDeprecated: Int64
        var isBeta: Int64
        var isReleaseNotes: Int64
        var kind: String
        var language: String
        var urlDepth: Int64
        // F6 denormalized columns (computed by `SearchDenorm`, byte-identical to the
        // SQLite expressions they replace in the read query).
        var titleLC: String
        var keyLC: String
        var yearNum: Int64?
        var trackLC: String
        var rootDisplay: String
        var rootSlug: String

        /// INSERT into the ADSQL `documents` table (bare-`?` positional binds).
        func insertADSQL(_ tx: SQLTransaction) throws(DBError) {
            try tx.run(
                SearchCorpus.adsqlInsertSQL,
                .integer(id), .text(key), .text(title), .text(role), .text(roleHeading),
                .text(abstract), .text(declaration), .text(headings), .text(platformsJSON),
                num(minIOSNum), num(minMacOSNum), num(minWatchOSNum), num(minTVOSNum),
                num(minVisionOSNum), .text(minIOS), .text(minMacOS), .text(minWatchOS),
                .text(minTVOS), .text(minVisionOS), .text(framework), .text(sourceType),
                .text(sourceMetadata), .integer(isDeprecated), .integer(isBeta),
                .integer(isReleaseNotes), .text(kind), .text(language), .integer(urlDepth),
                .text(titleLC), .text(keyLC), num(yearNum), .text(trackLC),
                .text(rootDisplay), .text(rootSlug))
        }

        /// Bind the same 34 columns positionally into a SQLite INSERT statement.
        func bindSQLite(_ stmt: OpaquePointer?) {
            let transient = SearchPagesScenario.transient
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_bind_text(stmt, 2, key, -1, transient)
            sqlite3_bind_text(stmt, 3, title, -1, transient)
            sqlite3_bind_text(stmt, 4, role, -1, transient)
            sqlite3_bind_text(stmt, 5, roleHeading, -1, transient)
            sqlite3_bind_text(stmt, 6, abstract, -1, transient)
            sqlite3_bind_text(stmt, 7, declaration, -1, transient)
            sqlite3_bind_text(stmt, 8, headings, -1, transient)
            sqlite3_bind_text(stmt, 9, platformsJSON, -1, transient)
            bindNum(stmt, 10, minIOSNum)
            bindNum(stmt, 11, minMacOSNum)
            bindNum(stmt, 12, minWatchOSNum)
            bindNum(stmt, 13, minTVOSNum)
            bindNum(stmt, 14, minVisionOSNum)
            sqlite3_bind_text(stmt, 15, minIOS, -1, transient)
            sqlite3_bind_text(stmt, 16, minMacOS, -1, transient)
            sqlite3_bind_text(stmt, 17, minWatchOS, -1, transient)
            sqlite3_bind_text(stmt, 18, minTVOS, -1, transient)
            sqlite3_bind_text(stmt, 19, minVisionOS, -1, transient)
            sqlite3_bind_text(stmt, 20, framework, -1, transient)
            sqlite3_bind_text(stmt, 21, sourceType, -1, transient)
            sqlite3_bind_text(stmt, 22, sourceMetadata, -1, transient)
            sqlite3_bind_int64(stmt, 23, isDeprecated)
            sqlite3_bind_int64(stmt, 24, isBeta)
            sqlite3_bind_int64(stmt, 25, isReleaseNotes)
            sqlite3_bind_text(stmt, 26, kind, -1, transient)
            sqlite3_bind_text(stmt, 27, language, -1, transient)
            sqlite3_bind_int64(stmt, 28, urlDepth)
            sqlite3_bind_text(stmt, 29, titleLC, -1, transient)
            sqlite3_bind_text(stmt, 30, keyLC, -1, transient)
            bindNum(stmt, 31, yearNum)
            sqlite3_bind_text(stmt, 32, trackLC, -1, transient)
            sqlite3_bind_text(stmt, 33, rootDisplay, -1, transient)
            sqlite3_bind_text(stmt, 34, rootSlug, -1, transient)
        }

        private func num(_ v: Int64?) -> Value { v.map(Value.integer) ?? .null }
        private func bindNum(_ stmt: OpaquePointer?, _ index: Int32, _ v: Int64?) {
            if let v { sqlite3_bind_int64(stmt, index, v) } else { sqlite3_bind_null(stmt, index) }
        }
    }

    /// Deterministic SplitMix64 stream (same constants as the test-support corpus
    /// + `BenchRNG` — no Foundation random/clock).
    struct Generator {
        private var state: UInt64 = 0x5EA_5_0010_C0FFEE

        private mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        private mutating func pick(_ array: [String]) -> String {
            array[Int(next() % UInt64(array.count))]
        }

        private mutating func sentence() -> String {
            "A \(pick(proseAdjectives)) \(pick(proseNouns)) that \(pick(proseVerbs)) the \(pick(proseAdjectives)) \(pick(proseNouns))"
        }

        /// One apple-docs-shaped row. The vocabulary is chosen so a single anchor
        /// term (a framework name, "view", "render", …) hits a meaningful fraction
        /// and bm25 ranking discriminates.
        mutating func next(id: Int64) -> Document {
            let framework = pick(frameworks)
            let display = frameworks.firstIndex(of: framework).map { _ in framework } ?? framework
            let stem = pick(typeStems)
            let role = pick(typeRoles)
            let typeName = stem + role
            let title = "\(displayCase(display)) \(typeName)"
            // Two prose sentences + the type name keeps abstracts in the ~120–200 B
            // range; the §2.3 projection copies these (the per-row TEXT cost).
            let abstract =
                "\(sentence()). \(sentence()). Use \(typeName) to \(pick(proseVerbs)) the \(pick(proseNouns))."
            let declType = ["struct", "final class", "enum", "actor", "protocol"][Int(next() % 5)]
            let declaration =
                "\(declType) \(typeName) : \(role), Sendable // declared in \(framework)"
            let headingCount = 2 + Int(next() % 3)
            let headings = (0..<headingCount).map { _ in pick(headingWords) }.joined(separator: " ")
            let key = "documentation/\(framework)/\(typeName.lowercased())-\(id)"

            let year = 2014 + Int64(next() % 13)  // 2014–2026
            let track = pick(tracks)
            let metadata = "{\"year\":\(year),\"track\":\"\(track)\"}"
            let platforms = "[\"ios\",\"macos\"]"

            // Platform floors: most rows carry an iOS floor, fewer the others; a
            // fraction leave them NULL (the `min_*_num IS NULL` passthrough arm).
            let iosFloor = pickFloor(bias: 0)
            let macFloor = pickFloor(bias: 1)
            let watchFloor = pickFloor(bias: 2)
            let tvFloor = pickFloor(bias: 2)
            let visionFloor: Int64? = (next() % 4 == 0) ? 1 + Int64(next() % 2) : nil

            let kind = pick(kinds)
            let roleHeading = kind == "article" ? "Article" : "Symbol"
            let docRole = kind == "symbol" ? "symbol" : kind
            // F6 denorm: fold the tier-string / year / track / roots scalars the §2.2
            // read query computes per match into precomputed columns. `roots` covers
            // the first 14 frameworks (LEFT JOIN hit ⇒ display_name); the last 6 miss
            // (COALESCE falls back to `framework`) — `SearchCorpus.rootEntry` resolves it.
            let rootHit = SearchCorpus.rootEntry(framework)
            return Document(
                id: id, key: key, title: title, role: docRole, roleHeading: roleHeading,
                abstract: abstract, declaration: declaration, headings: headings,
                platformsJSON: platforms,
                minIOSNum: iosFloor, minMacOSNum: macFloor, minWatchOSNum: watchFloor,
                minTVOSNum: tvFloor, minVisionOSNum: visionFloor,
                minIOS: iosFloor.map { "\($0).0" } ?? "", minMacOS: macFloor.map { "\($0).0" } ?? "",
                minWatchOS: watchFloor.map { "\($0).0" } ?? "", minTVOS: tvFloor.map { "\($0).0" } ?? "",
                minVisionOS: visionFloor.map { "\($0).0" } ?? "",
                framework: framework, sourceType: pick(sourceTypes), sourceMetadata: metadata,
                isDeprecated: next() % 6 == 0 ? 1 : 0, isBeta: next() % 8 == 0 ? 1 : 0,
                isReleaseNotes: next() % 50 == 0 ? 1 : 0, kind: kind, language: pick(languages),
                urlDepth: 2 + Int64(next() % 4),
                titleLC: SearchDenorm.lower(title), keyLC: SearchDenorm.lower(key),
                yearNum: SearchDenorm.yearNum(year), trackLC: SearchDenorm.trackLC(track),
                rootDisplay: SearchDenorm.rootDisplay(framework: framework, displayName: rootHit?.displayName),
                rootSlug: SearchDenorm.rootSlug(framework: framework, slug: rootHit?.slug))
        }

        /// An iOS-style major version floor, biased so different platforms cluster
        /// around different ranges; `bias` 2 (watch/tv) leaves more NULL.
        private mutating func pickFloor(bias: Int) -> Int64? {
            let roll = next() % 8
            if roll < UInt64(bias) { return nil }  // higher bias ⇒ more NULL
            return 13 + Int64(next() % 14)  // 13–26
        }

        /// Title-case the framework slug for the display title (e.g. "swiftui" →
        /// "SwiftUI" via the known display names, else capitalize the first letter).
        private func displayCase(_ slug: String) -> String {
            if let entry = roots.first(where: { $0.slug == slug }) { return entry.displayName }
            guard let first = slug.first else { return slug }
            return first.uppercased() + slug.dropFirst()
        }
    }
}

// MARK: - Workload (representative SearchPagesParams)

/// A dozen-plus representative `/search` requests drawn from the corpus
/// vocabulary: a spread of single anchor terms, prose/stemmed terms, AND/OR/prefix
/// MATCH shapes, and several filter bags so the §2.4 predicates bite — a framework
/// `=`, a `sources_json` IN-list, a year/track pair, a deprecated mode, and a
/// min-platform range. The `raw` term drives the tier `CASE`. (Named distinctly
/// from `Stats.swift`'s KV `Workload`.)
enum SearchWorkload {
    // The corpus concatenates the symbol type-name (e.g. "AsyncView"), so single
    // stems like "async" do NOT appear as standalone FTS tokens; the anchor terms
    // below are drawn from the prose vocabulary (nouns/verbs) + framework names,
    // which the generator emits as whole tokens — so every query matches a
    // meaningful, varied candidate set (verified via SEARCH_DIAG).
    static let params: [SearchPagesParams] = [
        // Bare anchor terms (no filter) — the §2.2 hot path, a spread of match sizes.
        SearchPagesParams(query: "swiftui", raw: "SwiftUI", limit: limit),
        SearchPagesParams(query: "view", raw: "View", limit: limit),
        SearchPagesParams(query: "render", raw: "Render", limit: limit),
        SearchPagesParams(query: "model", raw: "Model", limit: limit),
        SearchPagesParams(query: "context", raw: "Context", limit: limit),
        SearchPagesParams(query: "buffer", raw: "Buffer", limit: limit),
        // MATCH operators.
        SearchPagesParams(query: "view AND model", raw: "View", limit: limit),
        SearchPagesParams(query: "swiftui OR uikit", raw: "SwiftUI", limit: limit),
        SearchPagesParams(query: "render*", raw: "Render", limit: limit),
        SearchPagesParams(query: "layout OR gesture", raw: "Layout", limit: limit),
        // Filter bags (each predicate bites).
        SearchPagesParams(query: "view", raw: "View", limit: limit, framework: "swiftui"),
        SearchPagesParams(
            query: "model", raw: "Model", limit: limit, sourcesJSON: "[\"doc\",\"sample\"]"),
        SearchPagesParams(query: "render", raw: "Render", limit: limit, year: 2024),
        SearchPagesParams(query: "view", raw: "View", limit: limit, trackLike: "%concurrency%"),
        SearchPagesParams(
            query: "view", raw: "View", limit: limit, deprecatedMode: "exclude", minIOS: 17),
        // The closest shape to a live request: source_type + language='both' +
        // deprecated exclude + a min-iOS range, all at once.
        SearchPagesParams(
            query: "data", raw: "Data", limit: limit, sourceType: "doc", language: "both",
            deprecatedMode: "exclude", minIOS: 18),
    ]

    private static let limit = SearchPagesScenario.limit
}

import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// End-to-end acceptance: the same DDL, data, and queries run on ADSQL and on
/// real SQLite must produce identical results. The schema and the literal
/// corpus mirror the apple-docs consumer (documents + roots, the search /
/// listing / facet SELECTs); a cross-feature generator then fuzzes the whole
/// surface (joins, filters, json_each, GROUP BY, aggregates, ORDER BY, LIMIT).
private enum DocsCorpus {
  static let schema = [
    """
    CREATE TABLE documents(
      id INTEGER PRIMARY KEY, key TEXT NOT NULL, title TEXT, framework TEXT,
      language TEXT, source_type TEXT, source_metadata TEXT, is_deprecated INTEGER, role TEXT)
    """,
    "CREATE TABLE roots(id INTEGER PRIMARY KEY, slug TEXT NOT NULL, display_name TEXT)",
    "CREATE INDEX i_doc_framework ON documents(framework)",
    "CREATE INDEX i_doc_key ON documents(key)",
    "CREATE UNIQUE INDEX u_root_slug ON roots(slug)",
  ]

  static let frameworks = ["UIKit", "SwiftUI", "Foundation", "Combine"]  // Combine has no root
  static let titles = ["Button", "Stack View", "View Controller", "Data Task", "button bar", "Publisher"]
  static let languages: [Value] = [.null, .text("en"), .text("both"), .text("fr")]
  static let sourceTypes = ["api", "guide", "sample"]
  static let roles = ["symbol", "article"]

  static func quote(_ s: String) -> String {
    var out = "'"
    for character in s { out += (character == "'") ? "''" : String(character) }
    return out + "'"
  }
  static func literal(_ value: Value) -> String {
    switch value {
    case .null: return "NULL"
    case .integer(let i): return String(i)
    case .real(let d): return String(d)
    case .text(let s): return quote(s)
    case .blob: return "NULL"
    }
  }

  static func seedStatements() -> [String] {
    var statements: [String] = []
    statements.append(
      "INSERT INTO roots(id, slug, display_name) VALUES"
        + "(1,'UIKit','UI Kit'),(2,'SwiftUI','Swift UI'),(3,'Foundation','Foundation'),(4,'Metal',NULL)")

    for i in 1...44 {
      let framework: Value = (i % 13 == 0) ? .null : .text(frameworks[i % frameworks.count])
      let title: Value = (i % 11 == 0) ? .null : .text(titles[i % titles.count])
      let language = languages[i % languages.count]
      let sourceType: Value = (i % 9 == 0) ? .null : .text(sourceTypes[i % sourceTypes.count])
      let metadata: Value
      switch i % 4 {
      case 0: metadata = .text("{\"year\": \(2018 + i % 7)}")
      case 1: metadata = .text("{\"other\": 1}")
      case 2: metadata = .null
      default: metadata = .text("{\"year\": \(2020 + i % 5), \"beta\": true}")
      }
      let deprecated: Value = (i % 5 == 0) ? .null : .integer(Int64(i % 3 == 0 ? 1 : 0))
      let role: Value = .text(roles[i % roles.count])
      let row = [
        Value.integer(Int64(i)), .text("doc/\(frameworkSlug(framework))/\(i)"), title, framework,
        language, sourceType, metadata, deprecated, role,
      ]
      statements.append("INSERT INTO documents VALUES(\(row.map(literal).joined(separator: ",")))")
    }
    return statements
  }

  private static func frameworkSlug(_ framework: Value) -> String {
    if case .text(let s) = framework { return s.lowercased() }
    return "none"
  }

  static func build() throws -> (Database, SQLiteMirror, TempDir) {
    let dir = TempDir()
    let db = try Database.open(at: dir.file("acceptance.adsql"))
    let mirror = SQLiteMirror()
    for sql in schema + seedStatements() {
      try db.prepare(sql).run()
      try mirror.exec(sql)
    }
    return (db, mirror, dir)
  }
}

@Suite("SQL acceptance — apple-docs corpus")
struct SQLCorpusTests {
  // Listing within a framework + language fallback.
  static let listing = """
    SELECT d.id, d.key, COALESCE(r.display_name, d.framework) AS fw
    FROM documents d LEFT JOIN roots r ON r.slug = d.framework
    WHERE ($framework IS NULL OR d.framework = $framework)
      AND (d.language IS NULL OR d.language = $lang OR d.language = 'both')
    ORDER BY d.key, d.id
    LIMIT $limit
    """

  // The search SELECT (minus MATCH): tiered CASE, json_each source filter,
  // json_extract year filter, deprecation mode. `d.id` makes ties total.
  static let search = """
    SELECT d.id, d.key,
      CASE
        WHEN LOWER(d.title) = LOWER($raw) THEN 0
        WHEN LOWER(d.title) LIKE LOWER($raw) || '%' THEN 1
        WHEN INSTR(LOWER(d.title), LOWER($raw)) > 0 THEN 2
        ELSE 3
      END AS tier
    FROM documents d LEFT JOIN roots r ON r.slug = d.framework
    WHERE ($framework IS NULL OR d.framework = $framework)
      AND ($sources_json IS NULL OR d.source_type IN (SELECT value FROM json_each($sources_json)))
      AND ($year IS NULL OR CAST(json_extract(d.source_metadata, '$.year') AS INTEGER) = $year)
      AND ($deprecated_mode = 'include' OR COALESCE(d.is_deprecated, 0) = 0)
    ORDER BY tier, CASE WHEN d.role = 'symbol' THEN 0 ELSE 1 END, length(d.key), d.id
    LIMIT $limit
    """

  // Per-framework facet counts.
  static let facet = """
    SELECT d.framework, COUNT(*) AS n, SUM(COALESCE(d.is_deprecated, 0)) AS deprecated
    FROM documents d
    WHERE d.framework IS NOT NULL
    GROUP BY d.framework
    HAVING COUNT(*) >= $min
    ORDER BY d.framework
    """

  func check(_ db: Database, _ mirror: SQLiteMirror, _ sql: String, _ params: [String: Value]) throws {
    let ours = try db.prepare(sql).all(params).map(\.values)
    let theirs = try mirror.query(sql, named: params)
    #expect(rowsMatch(ours, theirs, ordered: true), "\(sql)\nparams \(params): \(ours) vs \(theirs)")
  }

  @Test func listingMatchesSQLite() throws {
    let (db, mirror, dir) = try DocsCorpus.build()
    defer { dir.cleanup(); db.close() }
    try check(db, mirror, Self.listing, ["framework": .text("UIKit"), "lang": .text("en"), "limit": .integer(50)])
    try check(db, mirror, Self.listing, ["framework": .null, "lang": .text("fr"), "limit": .integer(10)])
    try check(db, mirror, Self.listing, ["framework": .text("Combine"), "lang": .null, "limit": .integer(5)])
  }

  @Test func searchMatchesSQLite() throws {
    let (db, mirror, dir) = try DocsCorpus.build()
    defer { dir.cleanup(); db.close() }
    let base: [String: Value] = [
      "raw": .text("button"), "framework": .null, "sources_json": .null, "year": .null,
      "deprecated_mode": .text("exclude"), "limit": .integer(50),
    ]
    try check(db, mirror, Self.search, base)
    try check(db, mirror, Self.search, base.merging(["framework": .text("UIKit")]) { _, b in b })
    try check(db, mirror, Self.search, base.merging(["sources_json": .text("[\"api\",\"guide\"]")]) { _, b in b })
    try check(db, mirror, Self.search, base.merging(["year": .integer(2021)]) { _, b in b })
    try check(db, mirror, Self.search, base.merging(["deprecated_mode": .text("include")]) { _, b in b })
    try check(db, mirror, Self.search, ["raw": .text("view"), "framework": .null, "sources_json": .text("[\"sample\"]"), "year": .null, "deprecated_mode": .text("include"), "limit": .integer(3)])
  }

  @Test func facetMatchesSQLite() throws {
    let (db, mirror, dir) = try DocsCorpus.build()
    defer { dir.cleanup(); db.close() }
    try check(db, mirror, Self.facet, ["min": .integer(1)])
    try check(db, mirror, Self.facet, ["min": .integer(5)])
  }
}

@Suite("SQL acceptance — cross-feature fuzz")
struct SQLFuzzTests {
  @Test(arguments: [UInt64(101), 202, 303])
  func randomQueriesMatchSQLite(seed: UInt64) throws {
    let (db, mirror, dir) = try DocsCorpus.build()
    defer { dir.cleanup(); db.close() }

    var rng = SplitMix64(seed: seed)
    for _ in 0..<800 {
      let (sql, ordered) = Self.randomQuery(&rng)
      let ours = try db.prepare(sql).all().map(\.values)
      let theirs = try mirror.query(sql)
      #expect(rowsMatch(ours, theirs, ordered: ordered), "\(sql): adsql \(ours) vs sqlite \(theirs)")
    }
  }

  private static func randomQuery(_ rng: inout SplitMix64) -> (sql: String, ordered: Bool) {
    func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
    let fw = DocsCorpus.frameworks

    let predicates = [
      "d.framework = '\(pick(fw))'",
      "d.framework IS NULL",
      "d.framework IS NOT NULL",
      "d.language = 'en'",
      "d.language IS NULL",
      "d.id < \(5 + rng.next() % 40)",
      "d.id IN (\(1 + rng.next() % 44), \(1 + rng.next() % 44), \(1 + rng.next() % 44))",
      "d.source_type IN (SELECT value FROM json_each('[\"api\",\"sample\"]'))",
      "COALESCE(d.is_deprecated, 0) = 0",
      "d.title LIKE 'b%'",
      "CAST(json_extract(d.source_metadata, '$.year') AS INTEGER) > 2020",
    ]
    var clauses: [String] = []
    let predicateCount = Int(rng.next() % 3)
    for _ in 0..<predicateCount { clauses.append(pick(predicates)) }
    let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
    let join = (rng.next() % 2 == 0)
      ? " LEFT JOIN roots r ON r.slug = d.framework" : ""

    // Grouped (deterministic ORDER BY on the group column) or row query
    // (ORDER BY the unique id).
    if rng.next() % 3 == 0 {
      let agg = pick(["COUNT(*)", "COUNT(d.title)", "SUM(COALESCE(d.is_deprecated,0))"])
      var sql = "SELECT d.framework, \(agg) AS a FROM documents d\(join)\(whereClause)"
      sql += " GROUP BY d.framework"
      if rng.next() % 2 == 0 { sql += " HAVING COUNT(*) > \(rng.next() % 3)" }
      sql += " ORDER BY d.framework"
      return (sql, true)
    }

    let projection = pick(["d.id", "d.id, d.framework", "d.id, d.key, d.language"])
    var sql = "SELECT \(projection) FROM documents d\(join)\(whereClause) ORDER BY d.id"
    if rng.next() % 2 == 0 { sql += " LIMIT \(rng.next() % 20)" }
    return (sql, true)
  }
}

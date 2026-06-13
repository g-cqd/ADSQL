import Synchronization

/// Bound parameter values for one execution. Positional `?` markers are
/// 1-based by appearance order; `$name`/`:name` markers resolve by name
/// (without the sigil).
public struct SQLParameters: Sendable {
  public var positional: [Value]
  public var named: [String: Value]

  public init(positional: [Value] = [], named: [String: Value] = [:]) {
    self.positional = positional
    self.named = named
  }

  func lookup(_ parameter: SQLParam) throws(DBError) -> Value {
    switch parameter {
    case .positional(let index):
      guard index >= 1, index <= positional.count else {
        throw DBError.sqlBind("missing positional parameter ?\(index)")
      }
      return positional[index - 1]
    case .named(let name):
      guard let value = named[name] else {
        throw DBError.sqlBind("missing parameter for :\(name)/$\(name)")
      }
      return value
    }
  }
}

/// The column names of a result set, allocated once and shared by every
/// `SQLRow` it produces.
public final class SQLColumnHeader: Sendable {
  public let names: [String]
  let indexByName: [String: Int]

  init(_ names: [String]) {
    self.names = names
    var map: [String: Int] = [:]
    for (index, name) in names.enumerated() {
      let key = name.lowercased()
      if map[key] == nil { map[key] = index }  // first occurrence wins
    }
    self.indexByName = map
  }
}

/// One result row: positional values plus the shared column header for
/// name-based access.
public struct SQLRow: Sendable {
  public let header: SQLColumnHeader
  public let values: [Value]

  public var count: Int { values.count }
  public var columns: [String] { header.names }

  public subscript(_ index: Int) -> Value { values[index] }

  public subscript(_ name: String) -> Value? {
    header.indexByName[name.lowercased()].map { values[$0] }
  }
}

/// The outcome of a non-query execution.
public struct RunResult: Sendable {
  public let changes: Int
  public let lastInsertRowid: Int64

  public init(changes: Int = 0, lastInsertRowid: Int64 = 0) {
    self.changes = changes
    self.lastInsertRowid = lastInsertRowid
  }
}

/// A parsed, reusable statement. `prepare` only lexes and parses (no schema);
/// each execution binds against the transaction's schema and reuses the bound
/// plan while the catalog version is unchanged. Safe to share across tasks:
/// every execution opens its own transaction and uses its own row state, and
/// the bound-plan cache is mutex-guarded.
public final class Statement: Sendable {
  private unowned let database: Database
  public let sql: String
  let ast: SQLStatementAST
  public let isReadOnly: Bool

  private struct CachedPlan: Sendable {
    let catalogVersion: UInt64
    let plan: BoundSelect
  }
  private let cachedPlan = Mutex<CachedPlan?>(nil)

  init(database: Database, sql: String, parsed: ParsedStatement) {
    self.database = database
    self.sql = sql
    self.ast = parsed.ast
    self.isReadOnly = parsed.isReadOnly
  }

  // MARK: - Execution

  /// All result rows.
  public func all(_ parameters: Value...) throws(DBError) -> [SQLRow] {
    try all(SQLParameters(positional: parameters))
  }
  public func all(_ named: [String: Value]) throws(DBError) -> [SQLRow] {
    try all(SQLParameters(named: named))
  }
  public func all(_ parameters: SQLParameters) throws(DBError) -> [SQLRow] {
    try query(parameters)
  }

  /// The first result row, or nil.
  public func get(_ parameters: Value...) throws(DBError) -> SQLRow? {
    try query(SQLParameters(positional: parameters)).first
  }
  public func get(_ named: [String: Value]) throws(DBError) -> SQLRow? {
    try query(SQLParameters(named: named)).first
  }
  public func get(_ parameters: SQLParameters) throws(DBError) -> SQLRow? {
    try query(parameters).first
  }

  /// Executes for effect; rows (if any) are discarded.
  @discardableResult
  public func run(_ parameters: Value...) throws(DBError) -> RunResult {
    try run(SQLParameters(positional: parameters))
  }
  @discardableResult
  public func run(_ named: [String: Value]) throws(DBError) -> RunResult {
    try run(SQLParameters(named: named))
  }
  @discardableResult
  public func run(_ parameters: SQLParameters) throws(DBError) -> RunResult {
    if case .select = ast {
      _ = try query(parameters)
      return RunResult()
    }
    throw DBError.sqlUnsupported("write statements arrive in a later slice")
  }

  // MARK: - Internals

  private func query(_ parameters: SQLParameters) throws(DBError) -> [SQLRow] {
    guard case .select(let select) = ast else {
      throw DBError.sqlUnsupported("statement does not return rows")
    }
    return try database.read { txn throws(DBError) in
      let schema = try txn.schema()
      let plan = try self.boundSelect(select, schema: schema)
      let table = try txn.tableRecord(plan.source.table)
      var index: Catalog.IndexRecord?
      if let name = plan.access.indexName { index = try txn.indexRecord(name) }
      return try SelectExecutor.run(
        plan, table: table, index: index, resolver: txn.resolver, params: parameters)
    }
  }

  /// The chosen access path, SQLite-EXPLAIN-shaped (for planner assertions).
  public func planDescription() throws(DBError) -> String {
    guard case .select(let select) = ast else {
      throw DBError.sqlUnsupported("statement does not return rows")
    }
    return try database.read { txn throws(DBError) in
      let plan = try self.boundSelect(select, schema: try txn.schema())
      return plan.access.describe(table: plan.source.table)
    }
  }

  private func boundSelect(_ select: SQLSelect, schema: Schema) throws(DBError) -> BoundSelect {
    if let cached = cachedPlan.withLock({ $0 }), cached.catalogVersion == schema.catalogVersion {
      return cached.plan
    }
    let plan = try Binder.bindSelect(select, schema: schema)
    cachedPlan.withLock { existing in
      if existing == nil || existing!.catalogVersion <= schema.catalogVersion {
        existing = CachedPlan(catalogVersion: schema.catalogVersion, plan: plan)
      }
    }
    return plan
  }
}

// MARK: - Parse cache

/// The lex+parse product cached by SQL text (the schema-independent half of a
/// statement).
struct ParsedStatement: Sendable {
  let ast: SQLStatementAST
  let isReadOnly: Bool
}

/// A small LRU keyed by SQL text. Re-preparing a hot statement skips the
/// lexer and parser entirely.
struct StatementCache {
  let capacity: Int
  private var entries: [String: ParsedStatement] = [:]
  private var order: [String] = []  // oldest first

  init(capacity: Int) { self.capacity = capacity }

  mutating func get(_ sql: String) -> ParsedStatement? {
    guard let parsed = entries[sql] else { return nil }
    touch(sql)
    return parsed
  }

  mutating func insert(_ sql: String, _ parsed: ParsedStatement) {
    entries[sql] = parsed
    touch(sql)
    while order.count > capacity {
      let evicted = order.removeFirst()
      entries[evicted] = nil
    }
  }

  private mutating func touch(_ sql: String) {
    if let existing = order.firstIndex(of: sql) { order.remove(at: existing) }
    order.append(sql)
  }
}

extension Database {
  /// Parses `sql` (reusing the parse cache) into a reusable `Statement`.
  public func prepare(_ sql: String) throws(DBError) -> Statement {
    if let parsed = statementCache.withLock({ $0.get(sql) }) {
      return Statement(database: self, sql: sql, parsed: parsed)
    }
    let ast = try SQLParser.parseOne(sql)
    let parsed = ParsedStatement(ast: ast, isReadOnly: ast.isReadOnly)
    statementCache.withLock { $0.insert(sql, parsed) }
    return Statement(database: self, sql: sql, parsed: parsed)
  }
}

/// A multi-statement write transaction: every statement runs against one
/// shared `WriteTxn`, so a batch of writes commits once (one durability
/// point) instead of per statement. The handle is only valid inside the
/// `transaction` closure — using it afterward is undefined.
public final class SQLTransaction {
  private let database: Database
  private let ctx: TxnContext

  init(database: Database, ctx: TxnContext) {
    self.database = database
    self.ctx = ctx
  }

  @discardableResult
  public func run(_ sql: String, _ params: Value...) throws(DBError) -> RunResult {
    try run(sql, SQLParameters(positional: params))
  }
  @discardableResult
  public func run(_ sql: String, _ named: [String: Value]) throws(DBError) -> RunResult {
    try run(sql, SQLParameters(named: named))
  }
  @discardableResult
  public func run(_ sql: String, _ params: SQLParameters) throws(DBError) -> RunResult {
    let parsed = try database.parsedStatement(sql)
    switch parsed.ast {
    case .select, .begin, .commit, .rollback:
      throw DBError.sqlUnsupported(
        "only INSERT/UPDATE/DELETE/DDL run inside a transaction block")
    default:
      let txn = WriteTxn(ctx: ctx)
      return try Writer.execute(parsed.ast, txn: txn, params: params).result
    }
  }
}

extension Database {
  /// Parses (reusing the parse cache) without constructing a `Statement`.
  func parsedStatement(_ sql: String) throws(DBError) -> ParsedStatement {
    if let cached = statementCache.withLock({ $0.get(sql) }) { return cached }
    let ast = try SQLParser.parseOne(sql)
    let parsed = ParsedStatement(ast: ast, isReadOnly: ast.isReadOnly)
    statementCache.withLock { $0.insert(sql, parsed) }
    return parsed
  }

  /// Runs `body` against one exclusive write transaction; its statements
  /// commit together when `body` returns (or roll back if it throws).
  @discardableResult
  public func transaction<R>(
    _ body: (SQLTransaction) throws(DBError) -> R
  ) throws(DBError) -> R {
    try writeSync { (txn) throws(DBError) in
      try body(SQLTransaction(database: self, ctx: txn.ctx))
    }
  }
}

/// SQL abstract syntax. Value types, Sendable, carrying source offsets where
/// errors can surface later (bind/run time).
public indirect enum SQLExpr: Equatable, Sendable {
  case literal(Value)
  case column(table: String?, name: String, offset: Int)
  case parameter(SQLParam, offset: Int)
  case binary(SQLBinaryOp, SQLExpr, SQLExpr)
  case unary(SQLUnaryOp, SQLExpr)
  case like(SQLExpr, pattern: SQLExpr, negated: Bool)
  case isNull(SQLExpr, negated: Bool)
  case inList(SQLExpr, [SQLExpr], negated: Bool)
  /// The contracted shape `x IN (SELECT value FROM json_each(<expr>))`.
  case inJSONEach(SQLExpr, source: SQLExpr, negated: Bool)
  /// The contracted correlated scalar shape (single aggregate over one table).
  case scalarSubquery(SQLSelect)
  case caseWhen(operand: SQLExpr?, whens: [SQLWhen], elseExpr: SQLExpr?)
  case function(name: String, args: [SQLExpr], star: Bool, offset: Int)
  case cast(SQLExpr, ColumnType)
  case collate(SQLExpr, Collation)
  /// Internal: an aggregate's computed value for the current group. The binder
  /// rewrites COUNT/SUM calls to this so the evaluator computes group output
  /// rows with the ordinary expression machinery.
  case aggregateResult(Int)
}

public struct SQLWhen: Equatable, Sendable {
  public var condition: SQLExpr
  public var result: SQLExpr
}

public enum SQLBinaryOp: String, Equatable, Sendable {
  case eq = "="
  case ne = "!="
  case lt = "<"
  case le = "<="
  case gt = ">"
  case ge = ">="
  case and = "AND"
  case or = "OR"
  case add = "+"
  case subtract = "-"
  case multiply = "*"
  case divide = "/"
  case modulo = "%"
  case concat = "||"
}

public enum SQLUnaryOp: String, Equatable, Sendable {
  case negate = "-"
  case not = "NOT"
}

// MARK: - SELECT

public struct SQLSelect: Equatable, Sendable {
  public var distinct = false
  public var columns: [SQLResultColumn] = []
  public var from: SQLTableRef?
  public var joins: [SQLJoin] = []
  public var whereExpr: SQLExpr?
  public var groupBy: [SQLExpr] = []
  public var having: SQLExpr?
  public var compounds: [SQLCompound] = []
  public var orderBy: [SQLOrderingTerm] = []
  public var limit: SQLExpr?
  public var offset: SQLExpr?
}

public enum SQLResultColumn: Equatable, Sendable {
  case star
  case tableStar(String)
  /// `sourceText` names unaliased expression columns (SQLite behavior).
  case expr(SQLExpr, alias: String?, sourceText: String)
}

public struct SQLTableRef: Equatable, Sendable {
  public var name: String
  public var alias: String?
  public var offset: Int
}

public enum SQLJoinKind: Equatable, Sendable {
  case inner
  case left
}

public struct SQLJoin: Equatable, Sendable {
  public var kind: SQLJoinKind
  public var table: SQLTableRef
  public var on: SQLExpr
}

public enum SQLCompoundOp: Equatable, Sendable {
  case union
  case unionAll
}

public struct SQLCompound: Equatable, Sendable {
  public var op: SQLCompoundOp
  public var select: SQLSelect
}

public struct SQLOrderingTerm: Equatable, Sendable {
  public var expr: SQLExpr
  public var descending: Bool
}

// MARK: - Writes

public struct SQLInsert: Equatable, Sendable {
  public enum Conflict: Equatable, Sendable {
    case abort
    case replace // INSERT OR REPLACE
    case ignore  // INSERT OR IGNORE
    /// ON CONFLICT(column) DO UPDATE SET ...
    case doUpdate(target: String, sets: [SQLAssignment])
  }
  public var table: String
  public var columns: [String]
  public var rows: [[SQLExpr]]
  public var conflict: Conflict = .abort
  public var returning: [SQLResultColumn] = []
  public var offset: Int
}

public struct SQLAssignment: Equatable, Sendable {
  public var column: String
  public var value: SQLExpr
  public var offset: Int
}

public struct SQLUpdate: Equatable, Sendable {
  public var table: String
  public var sets: [SQLAssignment]
  public var whereExpr: SQLExpr?
  public var returning: [SQLResultColumn] = []
  public var offset: Int
}

public struct SQLDelete: Equatable, Sendable {
  public var table: String
  public var whereExpr: SQLExpr?
  public var returning: [SQLResultColumn] = []
  public var offset: Int
}

// MARK: - DDL

public struct SQLCreateTable: Equatable, Sendable {
  public var definition: TableDefinition
  /// Implicit unique indexes from column/table UNIQUE and non-rowid PKs,
  /// named sqlite_autoindex_<table>_<n>.
  public var impliedIndexes: [IndexDefinition]
  public var ifNotExists: Bool
}

public struct SQLCreateIndex: Equatable, Sendable {
  public var definition: IndexDefinition
  public var ifNotExists: Bool
}

// MARK: - Statements

public enum SQLStatementAST: Equatable, Sendable {
  case select(SQLSelect)
  case insert(SQLInsert)
  case update(SQLUpdate)
  case delete(SQLDelete)
  case createTable(SQLCreateTable)
  case createIndex(SQLCreateIndex)
  case dropTable(name: String, ifExists: Bool)
  case dropIndex(name: String, ifExists: Bool)
  case begin
  case commit
  case rollback

  public var isReadOnly: Bool {
    if case .select = self { return true }
    return false
  }
}

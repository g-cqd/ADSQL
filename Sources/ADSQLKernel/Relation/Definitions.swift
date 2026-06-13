public enum DefaultValue: Equatable, Sendable {
  case value(Value)
  /// Materialized at insert time as "YYYY-MM-DD HH:MM:SS" UTC.
  case datetimeNow
}

public struct ColumnDefinition: Equatable, Sendable {
  public var name: String
  public var type: ColumnType
  public var notNull: Bool
  public var collation: Collation
  public var defaultValue: DefaultValue?

  public init(
    _ name: String, _ type: ColumnType, notNull: Bool = false,
    collation: Collation = .binary, defaultValue: DefaultValue? = nil
  ) {
    self.name = name
    self.type = type
    self.notNull = notNull
    self.collation = collation
    self.defaultValue = defaultValue
  }
}

public enum PrimaryKey: Equatable, Sendable {
  /// Rows are keyed by a hidden monotonic rowid.
  case implicitRowid
  /// SQLite "INTEGER PRIMARY KEY [AUTOINCREMENT]": the column aliases rowid.
  case rowidAlias(column: String, autoincrement: Bool)
}

public enum FKAction: UInt8, Equatable, Sendable {
  case cascade = 1
  case restrict = 2
}

public struct ForeignKey: Equatable, Sendable {
  public var childColumns: [String]
  public var parentTable: String
  public var onDelete: FKAction

  public init(childColumns: [String], parentTable: String, onDelete: FKAction) {
    self.childColumns = childColumns
    self.parentTable = parentTable
    self.onDelete = onDelete
  }
}

public struct TableDefinition: Equatable, Sendable {
  public var name: String
  public var columns: [ColumnDefinition]
  public var primaryKey: PrimaryKey
  public var foreignKeys: [ForeignKey]

  public init(
    _ name: String, columns: [ColumnDefinition],
    primaryKey: PrimaryKey = .implicitRowid, foreignKeys: [ForeignKey] = []
  ) {
    self.name = name
    self.columns = columns
    self.primaryKey = primaryKey
    self.foreignKeys = foreignKeys
  }

  public func columnIndex(of name: String) -> Int? {
    columns.firstIndex { $0.name == name }
  }

  /// The rowid-alias column index, if the PK aliases rowid.
  public var rowidAliasIndex: Int? {
    if case .rowidAlias(let column, _) = primaryKey { return columnIndex(of: column) }
    return nil
  }

  public var isAutoincrement: Bool {
    if case .rowidAlias(_, let auto) = primaryKey { return auto }
    return false
  }

  func validate() throws(DBError) {
    guard !name.isEmpty, name.utf8.first != 0x00 else {
      throw DBError.invalidDefinition("table name must be non-empty")
    }
    guard !columns.isEmpty else {
      throw DBError.invalidDefinition("table \(name) has no columns")
    }
    var seen = Set<String>()
    for column in columns {
      guard !column.name.isEmpty else {
        throw DBError.invalidDefinition("table \(name): empty column name")
      }
      guard seen.insert(column.name).inserted else {
        throw DBError.invalidDefinition("table \(name): duplicate column \(column.name)")
      }
      if let defaultValue = column.defaultValue {
        switch defaultValue {
        case .datetimeNow:
          guard column.type == .text else {
            throw DBError.invalidDefinition(
              "table \(name).\(column.name): datetime('now') default requires TEXT")
          }
        case .value(.null):
          guard !column.notNull else {
            throw DBError.invalidDefinition(
              "table \(name).\(column.name): NULL default on NOT NULL column")
          }
        case .value(let value):
          if let type = value.columnType, type != column.type {
            throw DBError.invalidDefinition(
              "table \(name).\(column.name): default type \(value.typeName) ≠ \(column.type.name)")
          }
        }
      }
    }
    if case .rowidAlias(let column, _) = primaryKey {
      guard let index = columnIndex(of: column) else {
        throw DBError.invalidDefinition("table \(name): PK column \(column) not found")
      }
      guard columns[index].type == .integer else {
        throw DBError.invalidDefinition("table \(name): rowid alias \(column) must be INTEGER")
      }
    }
    for fk in foreignKeys {
      guard fk.childColumns.count == 1 else {
        throw DBError.invalidDefinition(
          "table \(name): foreign keys reference the parent rowid through exactly one column")
      }
      for column in fk.childColumns where columnIndex(of: column) == nil {
        throw DBError.noSuchColumn(table: name, column: column)
      }
    }
  }
}

public struct IndexDefinition: Equatable, Sendable {
  public var name: String
  public var table: String
  public var columns: [String]
  public var unique: Bool
  /// Non-key "covering" columns stored losslessly in each index entry's value
  /// (Postgres `INCLUDE` semantics). They don't affect key order or uniqueness;
  /// a scan that reads only `includes` columns (plus the rowid) is served
  /// index-only, with no descent into the table tree.
  public var includes: [String]

  public init(
    _ name: String, on table: String, columns: [String], unique: Bool = false,
    includes: [String] = []
  ) {
    self.name = name
    self.table = table
    self.columns = columns
    self.unique = unique
    self.includes = includes
  }

  func validate(against table: TableDefinition) throws(DBError) {
    guard !name.isEmpty else {
      throw DBError.invalidDefinition("index name must be non-empty")
    }
    guard !columns.isEmpty else {
      throw DBError.invalidDefinition("index \(name) has no columns")
    }
    var seen = Set<String>()
    for column in columns {
      guard table.columnIndex(of: column) != nil else {
        throw DBError.noSuchColumn(table: table.name, column: column)
      }
      guard seen.insert(column).inserted else {
        throw DBError.invalidDefinition("index \(name): duplicate column \(column)")
      }
    }
    for column in includes {
      guard table.columnIndex(of: column) != nil else {
        throw DBError.noSuchColumn(table: table.name, column: column)
      }
      guard !columns.contains(column) else {
        throw DBError.invalidDefinition(
          "index \(name): included column \(column) is already a key column")
      }
      guard seen.insert(column).inserted else {
        throw DBError.invalidDefinition("index \(name): duplicate included column \(column)")
      }
    }
  }
}

// MARK: - Full-text search (FTS5)

/// How an FTS table sources the column text it indexes.
public enum FTSContentMode: Equatable, Sendable {
  /// The FTS table stores the indexed columns itself.
  case selfContained
  /// `content='t' content_rowid='c'` — columns/length read from a base table.
  case external(table: String, rowid: String)
  /// `content=''` — no stored content; `contentless_delete=1` keeps deletes.
  case contentless(deleteEnabled: Bool)
}

/// `detail=` — how much positional data postings carry (trades phrase support
/// for size), mirroring FTS5.
public enum FTSDetail: Equatable, Sendable {
  case full
  case column
  case none
}

/// A parsed `USING fts5(…)` configuration. The `tokenize` spec is stored raw
/// (whitespace-split tokens, e.g. `["porter","unicode61"]`); tokenizers are
/// interpreted when they land (F1). Columns are plain text fields.
public struct FTSDefinition: Equatable, Sendable {
  public var name: String
  public var columns: [String]
  public var tokenize: [String]
  public var content: FTSContentMode
  public var prefix: [Int]
  public var detail: FTSDetail
  public var columnSize: Bool

  public init(
    name: String, columns: [String], tokenize: [String] = ["unicode61"],
    content: FTSContentMode = .selfContained, prefix: [Int] = [],
    detail: FTSDetail = .full, columnSize: Bool = true
  ) {
    self.name = name
    self.columns = columns
    self.tokenize = tokenize
    self.content = content
    self.prefix = prefix
    self.detail = detail
    self.columnSize = columnSize
  }

  public func columnIndex(of name: String) -> Int? {
    columns.firstIndex { $0 == name }
  }
}

/// An immutable schema snapshot (per committed generation).
public struct Schema: Sendable {
  public var catalogVersion: UInt64
  public var tables: [String: TableDefinition]
  public var indexes: [String: IndexDefinition]
  public var ftsTables: [String: FTSDefinition]

  /// Indexes of one table, name-sorted for deterministic maintenance order.
  public func indexes(on table: String) -> [IndexDefinition] {
    indexes.values.filter { $0.table == table }.sorted { $0.name < $1.name }
  }
}

public enum ConflictPolicy: Sendable {
  case abort
  case replace
  case ignore
}

public enum IndexBounds: Sendable {
  case all
  /// All entries whose leading columns equal these values.
  case prefix([Value])
  /// Typed range over the leading column(s).
  case range(lower: [Value]?, upper: [Value]?, lowerOpen: Bool, upperOpen: Bool)
}

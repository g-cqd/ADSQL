import ADSQLKernel

/// Naive relational oracle: dictionaries of rows plus recomputed index
/// orderings, mirroring ADSQL's externally visible semantics (strict types
/// assumed pre-validated by the caller; conflict policies, NULL-skipping
/// uniqueness, NaN→NULL, autoincrement monotonicity).
package struct RelationalModelStore: Sendable {
  package struct TableModel: Sendable {
    package var definition: TableDefinition
    package var rows: [Int64: [Value]] = [:]
    package var sequence: UInt64 = 0

    package init(definition: TableDefinition) {
      self.definition = definition
    }
  }

  package var tables: [String: TableModel] = [:]
  package var indexes: [String: IndexDefinition] = [:]

  package init() {}

  // MARK: - DDL mirror

  package mutating func createTable(_ definition: TableDefinition) {
    tables[definition.name] = TableModel(definition: definition)
  }

  package mutating func dropTable(_ name: String) {
    tables.removeValue(forKey: name)
    indexes = indexes.filter { $0.value.table != name }
  }

  package mutating func createIndex(_ definition: IndexDefinition) {
    indexes[definition.name] = definition
  }

  package mutating func dropIndex(_ name: String) {
    indexes.removeValue(forKey: name)
  }

  // MARK: - Helpers

  func collationEqual(_ a: Value, _ b: Value, _ collation: Collation) -> Bool {
    Value.keyOrder(a, b, collation: collation) == 0
  }

  func indexValues(_ index: IndexDefinition, _ table: TableModel, _ row: [Value]) -> [Value] {
    index.columns.map { row[table.definition.columnIndex(of: $0)!] }
  }

  func indexCollations(_ index: IndexDefinition, _ table: TableModel) -> [Collation] {
    index.columns.map { table.definition.columns[table.definition.columnIndex(of: $0)!].collation }
  }

  /// Conflicting rowids for `row` across the table's unique indexes
  /// (NULL-containing tuples never conflict), plus the index name hit first.
  func uniqueConflicts(
    table name: String, row: [Value], excluding: Int64?
  ) -> [(rowid: Int64, index: String)] {
    guard let table = tables[name] else { return [] }
    var hits: [(rowid: Int64, index: String)] = []
    for indexName in indexes.keys.sorted() {
      let index = indexes[indexName]!
      guard index.table == name, index.unique else { continue }
      let candidate = indexValues(index, table, row)
      guard !candidate.contains(where: \.isNull) else { continue }
      let collations = indexCollations(index, table)
      for (rowid, existing) in table.rows where rowid != excluding {
        let other = indexValues(index, table, existing)
        if zip(zip(candidate, other), collations).allSatisfy({
          collationEqual($0.0, $0.1, $1)
        }) {
          hits.append((rowid: rowid, index: indexName))
        }
      }
    }
    return hits
  }

  /// Assembles a row exactly as the engine does (no datetimeNow in
  /// property-test schemas; targeted tests cover it).
  package func assemble(
    table name: String, values: [String: Value]
  ) -> (row: [Value], explicitRowid: Int64?)? {
    guard let table = tables[name] else { return nil }
    let definition = table.definition
    var explicit: Int64?
    var row: [Value] = []
    for (index, column) in definition.columns.enumerated() {
      var value = values[column.name] ?? defaultValue(column)
      if case .real(let d) = value, d.isNaN { value = .null }
      if index == definition.rowidAliasIndex {
        if case .integer(let id) = value { explicit = id }
        row.append(.null)
        continue
      }
      row.append(value)
    }
    return (row, explicit)
  }

  private func defaultValue(_ column: ColumnDefinition) -> Value {
    switch column.defaultValue {
    case .value(let v): return v
    case .datetimeNow: return .text("<now>")
    case nil: return .null
    }
  }

  // MARK: - DML mirror

  package enum Outcome: Equatable, Sendable {
    case inserted(Int64)
    case ignored
    case uniqueViolation
  }

  package mutating func insert(
    into name: String, _ values: [String: Value], onConflict: ConflictPolicy
  ) -> Outcome {
    guard var table = tables[name],
      let assembled = assemble(table: name, values: values)
    else { return .ignored }
    var row = assembled.row
    let explicit = assembled.explicitRowid

    let rowid: Int64
    if let explicit {
      rowid = explicit
      if table.definition.isAutoincrement, explicit > 0,
        UInt64(explicit) > table.sequence {
        table.sequence = UInt64(explicit)
      }
    } else if table.definition.isAutoincrement {
      table.sequence += 1
      rowid = Int64(table.sequence)
    } else {
      rowid = (table.rows.keys.max() ?? 0) + 1
    }
    if let aliasIndex = table.definition.rowidAliasIndex {
      row[aliasIndex] = .integer(rowid)
    }

    // Allocation bookkeeping (the bumped sequence in `table`) persists only
    // when the insert succeeds — SQLite consumes nothing on abort/ignore.
    var conflicts = uniqueConflicts(table: name, row: row, excluding: nil)
    if explicit != nil, table.rows[rowid] != nil {
      conflicts.append((rowid: rowid, index: "rowid"))
    }

    if !conflicts.isEmpty {
      switch onConflict {
      case .abort:
        return .uniqueViolation
      case .ignore:
        return .ignored
      case .replace:
        for victim in Set(conflicts.map(\.rowid)) {
          table.rows.removeValue(forKey: victim)
        }
      }
    }
    table.rows[rowid] = row
    tables[name] = table
    return .inserted(rowid)
  }

  @discardableResult
  package mutating func update(
    _ name: String, rowid: Int64, set: [String: Value]
  ) -> Outcome? {
    guard let table = tables[name], var row = table.rows[rowid] else { return nil }
    for (column, provided) in set {
      var value = provided
      if case .real(let d) = value, d.isNaN { value = .null }
      row[table.definition.columnIndex(of: column)!] = value
    }
    if !uniqueConflicts(table: name, row: row, excluding: rowid).isEmpty {
      return .uniqueViolation
    }
    tables[name]!.rows[rowid] = row
    return .inserted(rowid)
  }

  @discardableResult
  package mutating func delete(from name: String, rowid: Int64) -> Bool {
    tables[name]?.rows.removeValue(forKey: rowid) != nil
  }

  // MARK: - Expected orderings

  package func sortedRows(_ name: String) -> [(rowid: Int64, values: [Value])] {
    guard let table = tables[name] else { return [] }
    return table.rows.keys.sorted().map { (rowid: $0, values: table.rows[$0]!) }
  }

  /// Rowids in index-key order (column tuple under collations, then rowid).
  package func indexOrder(_ indexName: String) -> [Int64] {
    guard let index = indexes[indexName], let table = tables[index.table] else { return [] }
    let collations = indexCollations(index, table)
    return table.rows.keys.sorted { a, b in
      let va = indexValues(index, table, table.rows[a]!)
      let vb = indexValues(index, table, table.rows[b]!)
      for i in 0..<va.count {
        let c = Value.keyOrder(va[i], vb[i], collation: collations[i])
        if c != 0 { return c < 0 }
      }
      return a < b
    }
  }
}

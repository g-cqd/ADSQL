/// Binding turns a parsed `SQLSelect` into a `BoundSelect`: the abstract
/// syntax resolved against a concrete schema version. Binding is the only
/// step that needs the schema, so a `Statement` caches one bound plan per
/// committed catalog version (a DDL commit invalidates it). M4/PR3 binds the
/// single-table shape only — joins, aggregates, and compound selects are
/// rejected here with named `sqlUnsupported` errors and arrive in later
/// slices.

/// One table reference resolved against the schema: the columns in declared
/// order plus a case-insensitive name→index map. The `binding` name is the
/// alias if present, else the table name; qualified column references must
/// match it.
struct TableBinding: Sendable {
  let table: String
  let binding: String           // lowercased alias-or-name for qualifier match
  let columnNames: [String]     // original case, declared order
  let columnTypes: [ColumnType]
  let columnCollations: [Collation]
  let indexByName: [String: Int]  // lowercased name → column index
  let rowidAliasIndex: Int?
  /// True for an FTS5 virtual table reference. Its `definition` is synthetic
  /// (a single `rowid` alias column), so `f.rowid` resolves to slot 0 and a
  /// bare `f` reference is the MATCH subject; the planner produces `.fts` from
  /// the MATCH conjunct rather than from indexes, and the executor drives the
  /// row source through `FTSMatch.evaluate` (no base scan).
  let isFTS: Bool

  init(reference: SQLTableRef, definition: TableDefinition, isFTS: Bool = false) {
    self.table = definition.name
    self.binding = (reference.alias ?? definition.name).lowercased()
    self.columnNames = definition.columns.map(\.name)
    self.columnTypes = definition.columns.map(\.type)
    self.columnCollations = definition.columns.map(\.collation)
    var map: [String: Int] = [:]
    for (index, column) in definition.columns.enumerated() {
      map[column.name.lowercased()] = index
    }
    self.indexByName = map
    self.rowidAliasIndex = definition.rowidAliasIndex
    self.isFTS = isFTS
  }

  func columnIndex(qualifier: String?, name: String) -> Int? {
    if let qualifier, qualifier.lowercased() != binding { return nil }
    return indexByName[name.lowercased()]
  }
}

/// The executor and planner model an FTS5 table as an ordinary rowid-keyed
/// table with two synthetic columns: slot 0 is the `rowid` alias (`RowSlot`
/// returns the docid without touching any record span, so the empty span the
/// `.fts` source supplies is never read; `f.rowid` joins the base table), and
/// slot 1 is `rank` — the bm25 relevance score the `.fts` source computes per
/// matching doc (F4). `f.rank` / bare `rank` resolves to slot 1 and reads the
/// score via `RowSlot.compute`'s `scoreIndex` path, parallel to the rowid path.
/// The `bm25()` index of the rank slot.
let ftsRankSlot = 1

func syntheticFTSDefinition(_ name: String) -> TableDefinition {
  TableDefinition(
    name, columns: [ColumnDefinition("rowid", .integer), ColumnDefinition("rank", .real)],
    primaryKey: .rowidAlias(column: "rowid", autoincrement: false))
}

extension TableDefinition {
  /// The `rank` score-column index for a synthetic FTS definition (the
  /// `[rowid, rank]` shape `syntheticFTSDefinition` builds), else nil. Lets the
  /// executor's `RowSlot` recognize the score slot without a separate flag.
  var ftsScoreIndex: Int? {
    guard columns.count == 2, rowidAliasIndex == 0,
      columns[ftsRankSlot].name == "rank", columns[ftsRankSlot].type == .real
    else { return nil }
    return ftsRankSlot
  }
}

/// A projected output column: its result-set name and the expression that
/// produces it.
struct BoundOutput: Sendable {
  let name: String
  let expr: SQLExpr
}

/// One join in a nested-loop plan: the right-hand table (by index into the
/// query's tables) and its ON predicate. INNER filters matches; LEFT emits one
/// null-extended row when the right side has no match.
struct BoundJoin: Sendable {
  let kind: SQLJoinKind
  let table: Int
  let on: SQLExpr
  /// Index-nested-loop access for this inner table: the index/rowid probe whose
  /// equality values are *outer* expressions (evaluated per outer row). A
  /// superset of the ON-matching rows — ON is still re-applied at the leaf — so
  /// it never changes results, only how many inner rows are touched.
  /// `.tableScan` = full inner scan (no usable equality on an indexed column).
  let access: AccessPlan
  /// The inner table can be visited as a pure index/rowid *existence* probe — no
  /// table descent, no ON re-evaluation, no materialization — because (1) the
  /// access is an exact-equality probe whose covered conjuncts are the *entire*
  /// ON predicate, and (2) no column of this inner table is read anywhere else
  /// (projection / WHERE / HAVING / ORDER BY / GROUP BY / another join). The
  /// executor still null-extends LEFT non-matches via the `matched` flag. When
  /// false, the normal descend+re-eval path runs (and is the safe fallback at
  /// runtime if the probe degrades to a scan).
  let innerExistenceOnly: Bool
}

/// All tables in a query's FROM/JOIN list, with column resolution across them.
struct QueryBinding: Sendable {
  let tables: [TableBinding]

  /// Resolves (qualifier, name) to (table index, column index). Unqualified
  /// names that match more than one table are ambiguous (nil → the evaluator
  /// reports no-such-column).
  func resolve(qualifier: String?, name: String) -> (table: Int, column: Int)? {
    let key = name.lowercased()
    if let qualifier {
      let q = qualifier.lowercased()
      for (index, table) in tables.enumerated() where table.binding == q {
        return table.indexByName[key].map { (index, $0) }
      }
      return nil
    }
    var found: (Int, Int)?
    for (index, table) in tables.enumerated() {
      if let column = table.indexByName[key] {
        if found != nil { return nil }  // ambiguous
        found = (index, column)
      }
    }
    return found
  }
}

/// A SELECT resolved against one schema version: one or more tables (the first
/// is the leading/outer table), joins, projection, filters, and ordering. The
/// access plan optimizes the leading table; joined tables nested-loop scan.
struct BoundSelect: Sendable {
  let binding: QueryBinding
  let joins: [BoundJoin]
  let outputs: [BoundOutput]
  let outputCollations: [Collation]
  let whereExpr: SQLExpr?
  /// WHERE with the conjuncts an exact probe covers removed — used (single
  /// table only) when the executor takes that probe, else `whereExpr`.
  let residualWithoutCovered: SQLExpr?
  let orderBy: [SQLOrderingTerm]
  let orderCollations: [Collation]
  /// GROUP BY key expressions and their collations (empty for a single
  /// implicit group when aggregates appear without GROUP BY).
  let groupBy: [SQLExpr]
  let groupCollations: [Collation]
  /// HAVING, rewritten so aggregate calls are `aggregateResult` slots.
  let having: SQLExpr?
  /// Aggregate slots referenced by the rewritten outputs/having/orderBy.
  let aggregates: [AggregateSpec]
  let isAggregated: Bool
  let distinct: Bool
  let limit: SQLExpr?
  let offset: SQLExpr?
  let header: SQLColumnHeader
  let access: AccessPlan
  /// The access path's natural order satisfies ORDER BY.
  let accessYieldsOrder: Bool
  /// Table (rowid) order satisfies ORDER BY — used on index→scan fallback.
  let rowidOrderSatisfiesOrderBy: Bool
  /// Tables whose column values a GROUP BY group's *representative* row must
  /// supply (referenced by outputs / HAVING / ORDER BY / GROUP BY). A table not
  /// in this set is never read during aggregate finalization, so `runAggregated`
  /// can skip materializing its representative — required for an existence-only
  /// join inner (whose slot holds an empty span), and a COUNT(*) win otherwise.
  let finalizationReferencedTables: Set<Int>
  /// An index to satisfy `SELECT DISTINCT <cols>` directly: its key columns are
  /// exactly the distinct outputs (all losslessly key-decodable, i.e. not NOCASE
  /// text), there is no WHERE/ORDER BY/join/aggregate. The executor scans it in
  /// key order, emitting one row per distinct key prefix decoded from the key —
  /// no table descent, no per-row dedup set. nil ⇒ the row-at-a-time path.
  let distinctIndexName: String?

  /// The leading (outer) table — the one the access plan optimizes.
  var source: TableBinding { binding.tables[0] }
  var isJoin: Bool { !joins.isEmpty }
}

/// A prepared query: a single SELECT or a UNION/UNION ALL of SELECT arms.
enum BoundQuery: Sendable {
  case select(BoundSelect)
  case compound(BoundCompound)
}

/// A left-associative compound: arms combined in order (the first arm's op is
/// nil), then a compound-level ORDER BY/LIMIT/OFFSET resolved against the
/// first arm's result columns.
struct BoundCompound: Sendable {
  struct Arm: Sendable {
    let op: SQLCompoundOp?
    let select: BoundSelect
  }
  struct CompoundOrder: Sendable {
    let index: Int          // result-column index
    let descending: Bool
    let collation: Collation
  }
  let arms: [Arm]
  let header: SQLColumnHeader
  let outputCollations: [Collation]
  let order: [CompoundOrder]
  let limit: SQLExpr?
  let offset: SQLExpr?
}


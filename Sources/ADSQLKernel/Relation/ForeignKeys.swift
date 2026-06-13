/// ON DELETE actions. M3 foreign keys reference the parent's rowid (the
/// INTEGER PRIMARY KEY alias) through exactly one child column — the shape
/// apple-docs uses everywhere (`document_id REFERENCES documents(id)`).
///
/// Cascades require an index whose leading column is the FK column; unlike
/// SQLite there is no full-scan fallback — a missing index is a typed error
/// at delete time. Worklist-driven, so chains (documents → sections →
/// chunks) and self-references terminate (rows physically disappear).
extension Relation {
  /// Child FK edges pointing at `parentName`, with the index that serves them.
  static func childEdges(
    state: RelationState, parent parentName: String
  ) throws(DBError) -> [(table: String, fk: ForeignKey, index: Catalog.IndexRecord)] {
    var edges: [(table: String, fk: ForeignKey, index: Catalog.IndexRecord)] = []
    for childName in state.tableRecords.keys.sorted() {
      let child = state.tableRecords[childName]!
      for fk in child.definition.foreignKeys where fk.parentTable == parentName {
        guard fk.childColumns.count == 1 else {
          throw DBError.invalidDefinition(
            "foreign keys reference the parent rowid through exactly one column")
        }
        let column = fk.childColumns[0]
        let serving = state.indexRecords.values
          .filter { $0.tableId == child.tableId && $0.definition.columns.first == column }
          .sorted { $0.definition.name < $1.definition.name }
          .first
        guard let index = serving else {
          throw DBError.invalidDefinition(
            "ON DELETE on \(parentName) requires an index leading with "
              + "\(childName).\(column)")
        }
        edges.append((table: childName, fk: fk, index: index))
      }
    }
    return edges
  }

  /// Child rowids whose FK column equals the deleted parent rowid.
  static func referencingRowids(
    _ ctx: TxnContext, index: Catalog.IndexRecord, table: Catalog.TableRecord,
    parentRowid: Int64
  ) throws(DBError) -> [Int64] {
    let collations = indexCollations(index.definition, table: table.definition)
    let prefix = try KeyCodec.encode(
      [.integer(parentRowid)], collations: [collations[0]])
    var rowids: [Int64] = []
    var cursor = Cursor(resolver: ctx, tree: index.handle)
    var failure: DBError?
    var positioned = false
    prefix.withUnsafeBytes { raw in
      do throws(DBError) {
        _ = unsafe try cursor.seek(raw)
        positioned = cursor.isValid
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
    while positioned {
      let rowid: Int64?? = unsafe try cursor.withCurrent { (key, _) throws(DBError) in
        let matches = prefix.withUnsafeBytes { p in
          unsafe key.count >= p.count
            && key.prefix(p.count).elementsEqual(UnsafeRawBufferPointer(rebasing: p[...]))
        }
        guard matches else { return nil }
        return unsafe KeyCodec.rowid(fromSuffixOf: key)
      }
      guard let hit = rowid ?? nil else { break }
      rowids.append(hit)
      positioned = try cursor.next()
    }
    return rowids
  }

  /// Applies ON DELETE actions for every freshly deleted (table, rowid).
  static func processDeleteActions(
    _ ctx: TxnContext, deleted: [(table: String, rowid: Int64)]
  ) throws(DBError) {
    var worklist = deleted
    while let (parentName, parentRowid) = worklist.popLast() {
      let state = try ensureState(ctx)
      for edge in try childEdges(state: state, parent: parentName) {
        guard let childTable = state.tableRecords[edge.table] else { continue }
        let victims = try referencingRowids(
          ctx, index: edge.index, table: childTable, parentRowid: parentRowid)
        guard !victims.isEmpty else { continue }
        switch edge.fk.onDelete {
        case .restrict:
          throw DBError.foreignKeyViolation(table: edge.table)
        case .cascade:
          for victim in victims {
            if try deleteRowCore(ctx, from: edge.table, rowid: victim) {
              worklist.append((table: edge.table, rowid: victim))
            }
          }
        }
      }
    }
  }
}

/// A materialized table row.
public struct Row: Equatable, Sendable {
  public let rowid: Int64
  let names: [String]
  public let values: [Value]

  public subscript(_ column: String) -> Value? {
    names.firstIndex(of: column).map { values[$0] }
  }

  public func integer(_ column: String) -> Int64? {
    if case .integer(let v)? = self[column] { return v }
    return nil
  }
  public func real(_ column: String) -> Double? {
    if case .real(let v)? = self[column] { return v }
    return nil
  }
  public func text(_ column: String) -> String? {
    if case .text(let v)? = self[column] { return v }
    return nil
  }
  public func blob(_ column: String) -> [UInt8]? {
    if case .blob(let v)? = self[column] { return v }
    return nil
  }
}

/// A lazy, read-only view of one row during a scan callback. Where the eager
/// `Row` decodes every column into a `[Value]` and builds a name array up
/// front, `RowView` decodes a single column on demand — walking the record
/// header just far enough to reach it, with no allocation and no work for
/// columns the caller never touches.
///
/// Noncopyable **and `~Escapable`**: it borrows a `RawSpan` view of a mapped
/// page valid only for the callback that receives it, and the compiler now
/// *enforces* that it cannot outlive that borrow (Review 0001 F1 — `@safe`
/// previously only asserted this). A scan reads columns through it on demand;
/// trying to store or return one fails to compile.
public struct RowView: ~Copyable, ~Escapable {
  public let rowid: Int64
  let definition: TableDefinition
  let span: RawSpan
  /// Index-only scans: when non-nil, `span` is the index entry's covering value
  /// (a `RecordCodec` record of these columns, in order) rather than the full
  /// table record. Reading the rowid-alias yields the rowid; reading a covered
  /// column decodes it from the value; reading any other column traps (the scan
  /// guaranteed it touches only covered columns).
  let coveringIncludes: [String]?

  @_lifetime(copy span)
  init(
    rowid: Int64, definition: TableDefinition, span: RawSpan,
    coveringIncludes: [String]? = nil
  ) {
    self.rowid = rowid
    self.definition = definition
    self.span = span
    self.coveringIncludes = coveringIncludes
  }

  /// Decode position of schema column `index` within a covering entry's value,
  /// or nil when the column isn't part of the covering set.
  private func coveringSlot(_ index: Int) -> Int? {
    coveringIncludes?.firstIndex(of: definition.columns[index].name)
  }

  /// The value of the column at `index` (schema order). Columns a short row did
  /// not store (e.g. after a future ADD COLUMN) read as their DEFAULT/NULL; the
  /// rowid-alias column reads as the rowid.
  public func value(at index: Int) throws(DBError) -> Value {
    precondition(index >= 0 && index < definition.columns.count, "column index out of range")
    if let alias = definition.rowidAliasIndex, index == alias { return .integer(rowid) }
    if coveringIncludes != nil {
      guard let slot = coveringSlot(index) else {
        preconditionFailure("column \(definition.columns[index].name) not covered by this index-only scan")
      }
      return try RecordCodec.value(at: slot, in: span, defaults: definition.columns)
    }
    return try RecordCodec.value(at: index, in: span, defaults: definition.columns)
  }

  /// The value of the named column, or nil when no such column exists.
  public func value(_ name: String) throws(DBError) -> Value? {
    guard let index = definition.columnIndex(of: name) else { return nil }
    return try value(at: index)
  }

  /// Zero-copy access to a TEXT column's UTF-8 bytes (no `String` allocation):
  /// `body` receives the bytes in place — valid only for the call — or `nil`
  /// when the column is NULL, not TEXT, or the rowid-alias. Pair with a column
  /// index resolved once (`definition.columnIndex(of:)`) on hot scans.
  public func withText<R>(
    at index: Int, _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    precondition(index >= 0 && index < definition.columns.count, "column index out of range")
    if let alias = definition.rowidAliasIndex, index == alias { return try body(nil) }
    if coveringIncludes != nil {
      guard let slot = coveringSlot(index) else {
        preconditionFailure("column \(definition.columns[index].name) not covered by this index-only scan")
      }
      return unsafe try RecordCodec.withText(at: slot, in: span, body)
    }
    return unsafe try RecordCodec.withText(at: index, in: span, body)
  }

  /// Zero-copy access to a BLOB column's raw bytes (no `[UInt8]` allocation);
  /// `body` gets `nil` when the column is NULL or not a BLOB.
  public func withBlob<R>(
    at index: Int, _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    precondition(index >= 0 && index < definition.columns.count, "column index out of range")
    if let alias = definition.rowidAliasIndex, index == alias { return try body(nil) }
    if coveringIncludes != nil {
      guard let slot = coveringSlot(index) else {
        preconditionFailure("column \(definition.columns[index].name) not covered by this index-only scan")
      }
      return unsafe try RecordCodec.withBlob(at: slot, in: span, body)
    }
    return unsafe try RecordCodec.withBlob(at: index, in: span, body)
  }

  public func integer(_ name: String) throws(DBError) -> Int64? {
    if case .integer(let v)? = try value(name) { return v }
    return nil
  }
  public func real(_ name: String) throws(DBError) -> Double? {
    if case .real(let v)? = try value(name) { return v }
    return nil
  }
  public func text(_ name: String) throws(DBError) -> String? {
    if case .text(let v)? = try value(name) { return v }
    return nil
  }
  public func blob(_ name: String) throws(DBError) -> [UInt8]? {
    if case .blob(let v)? = try value(name) { return v }
    return nil
  }
}

/// Forward iteration over a table (rowid order) or an index (key order),
/// materializing rows. Index cursors resolve each entry's rowid back into
/// the table tree; a dangling entry is corruption and throws.
public struct RowCursor<R: PageResolver>: ~Copyable {
  enum Mode {
    case table
    case index(Catalog.IndexRecord)
  }

  let resolver: R
  let table: Catalog.TableRecord
  let mode: Mode
  /// Exclusive upper bound on the iterated tree's keys.
  let upperKey: [UInt8]?
  /// Index-only scan: the index's covering columns (entry-value layout). When
  /// set (index mode only), rows are served from the entry value with no table
  /// descent. Nil = ordinary scan.
  let coveringIncludes: [String]?
  var cursor: Cursor<R>
  var exhausted = false

  init(
    resolver: R, table: Catalog.TableRecord, mode: Mode,
    lowerKey: [UInt8]?, upperKey: [UInt8]?, coveringIncludes: [String]? = nil
  ) throws(DBError) {
    self.resolver = resolver
    self.table = table
    self.mode = mode
    self.upperKey = upperKey
    self.coveringIncludes = coveringIncludes
    let tree: TreeHandle =
      switch mode {
      case .table: table.handle
      case .index(let index): index.handle
      }
    self.cursor = Cursor(resolver: resolver, tree: tree)
    if let lowerKey {
      var failure: DBError?
      var valid = false
      lowerKey.withUnsafeBytes { raw in
        do throws(DBError) {
          _ = unsafe try cursor.seek(raw)
          valid = cursor.isValid
        } catch {
          failure = error
        }
      }
      if let failure { throw failure }
      exhausted = !valid
    } else {
      exhausted = !(try cursor.move(to: .first))
    }
  }

  /// The next `(rowid, record bytes)` without materializing into a `Row`, or
  /// nil at the end of the bounds. The lazy-decode scan path builds its own
  /// on-demand row view over these bytes; `next()` layers full
  /// materialization on top.
  public mutating func nextRecord() throws(DBError) -> (rowid: Int64, record: [UInt8])? {
    guard !exhausted else { return nil }
    let entry: (rowid: Int64, record: [UInt8]?)? = unsafe try cursor.withCurrent {
      (key, ref) throws(DBError) in
      if let upperKey {
        let inBounds = upperKey.withUnsafeBytes { upper in
          unsafe Node.compare(key, UnsafeRawBufferPointer(rebasing: upper[...])) < 0
        }
        guard inBounds else { return nil }
      }
      guard let rowid = unsafe KeyCodec.rowid(fromSuffixOf: key) else {
        throw DBError.integrityFailure("malformed key in \(table.definition.name)")
      }
      switch mode {
      case .table:
        return (rowid: rowid, record: try BTree.copyValue(ref, resolver: resolver))
      case .index:
        return (rowid: rowid, record: nil)
      }
    } ?? nil

    guard let entry else {
      exhausted = true
      return nil
    }

    let recordBytes: [UInt8]
    if let bytes = entry.record {
      recordBytes = bytes
    } else {
      guard
        let bytes = try Relation.getBytes(
          resolver, table.handle, key: KeyCodec.rowKey(entry.rowid))
      else {
        throw DBError.integrityFailure(
          "dangling index entry: \(table.definition.name) rowid \(entry.rowid)")
      }
      recordBytes = bytes
    }
    exhausted = !(try cursor.next())
    return (entry.rowid, recordBytes)
  }

  /// Zero-copy push iteration: invokes `body(rowid, recordSpan)` for each row
  /// in bounds, where `recordSpan` is a view into the mapped page valid only
  /// for that call (no per-row record copy for inline values; overflow values
  /// are assembled once and spanned). `body` returns false to stop early.
  public mutating func forEachRecordSpan(
    _ body: (Int64, UnsafeRawBufferPointer) throws(DBError) -> Bool
  ) throws(DBError) {
    switch mode {
    case .table:
      while !exhausted {
        let step: Bool? = unsafe try cursor.withCurrent { (key, ref) throws(DBError) -> Bool? in
          if let upperKey, unsafe !Self.inBounds(key, below: upperKey) { return nil }
          guard let rowid = unsafe KeyCodec.rowid(fromSuffixOf: key) else {
            throw DBError.integrityFailure("malformed key in \(table.definition.name)")
          }
          return unsafe try BTree.withValueBytes(ref, resolver: resolver) { span throws(DBError) in
            unsafe try body(rowid, span)
          }
        } ?? nil
        guard let proceed = step else { exhausted = true; return }
        if !proceed { return }
        exhausted = !(try cursor.next())
      }
    case .index where coveringIncludes != nil:
      // Index-only scan: every needed column lives in the entry's covering
      // value, so serve it straight from the index leaf — no table descent.
      while !exhausted {
        let step: Bool? = unsafe try cursor.withCurrent { (key, ref) throws(DBError) -> Bool? in
          if let upperKey, unsafe !Self.inBounds(key, below: upperKey) { return nil }
          guard let rowid = unsafe KeyCodec.rowid(fromSuffixOf: key) else {
            throw DBError.integrityFailure("malformed key in \(table.definition.name)")
          }
          return unsafe try BTree.withValueBytes(ref, resolver: resolver) { span throws(DBError) in
            unsafe try body(rowid, span)
          }
        } ?? nil
        guard let proceed = step else { exhausted = true; return }
        if !proceed { return }
        exhausted = !(try cursor.next())
      }
    case .index:
      // Index entries within a probe arrive in (columns…, rowid) order, so the
      // rowids are ascending; a warm table cursor (`seekForward`) skips the
      // root→leaf descent whenever the next rowid is in the leaf it already
      // holds. The row fetch happens outside the index cursor's scope so the
      // two cursors never alias.
      var tableCursor = Cursor(resolver: resolver, tree: table.handle)
      while !exhausted {
        let rowid: Int64? = unsafe try cursor.withCurrent { (key, _) throws(DBError) -> Int64? in
          if let upperKey, unsafe !Self.inBounds(key, below: upperKey) { return nil }
          guard let rowid = unsafe KeyCodec.rowid(fromSuffixOf: key) else {
            throw DBError.integrityFailure("malformed key in \(table.definition.name)")
          }
          return rowid
        } ?? nil
        guard let rowid else { exhausted = true; return }

        var found: Result<Bool, DBError> = .success(false)
        withUnsafeTemporaryAllocation(byteCount: 8, alignment: 8) { raw in
          unsafe KeyCodec.writeRowKey(rowid, into: raw)
          do throws(DBError) {
            found = unsafe .success(try tableCursor.seekForward(UnsafeRawBufferPointer(raw)))
          } catch {
            found = .failure(error)
          }
        }
        guard try found.get() else {
          throw DBError.integrityFailure(
            "dangling index entry: \(table.definition.name) rowid \(rowid)")
        }
        let proceed: Bool = unsafe try tableCursor.withCurrent { (_, rowRef) throws(DBError) in
          unsafe try BTree.withValueBytes(rowRef, resolver: resolver) { span throws(DBError) in
            unsafe try body(rowid, span)
          }
        } ?? false
        if !proceed { return }
        exhausted = !(try cursor.next())
      }
    }
  }

  private static func inBounds(
    _ key: UnsafeRawBufferPointer, below upperKey: [UInt8]
  ) -> Bool {
    upperKey.withUnsafeBytes { upper in
      unsafe Node.compare(key, UnsafeRawBufferPointer(rebasing: upper[...])) < 0
    }
  }

  /// Lazy push scan: invokes `body` with a `RowView` per row in bounds, where
  /// each column decodes on demand (no per-row `Row` materialization). `body`
  /// returns false to stop early; the view is valid only for that call.
  public mutating func forEachRow(
    _ body: (borrowing RowView) throws(DBError) -> Bool
  ) throws(DBError) {
    let definition = table.definition
    // Bind each record span to the resolver (the snapshot owner). A `RowView`
    // borrowing it therefore cannot outlive the snapshot: escaping the scan —
    // exactly the use-after-free the page recycler would make silent — fails
    // to compile (Review 0001 F1). `resolver` is captured locally so the bound
    // views also cannot escape this call.
    let resolver = self.resolver
    // For an index-only scan, `span` is the covering entry value, decoded
    // through `coveringIncludes`; otherwise it's the full table record.
    let covering = coveringIncludes
    unsafe try forEachRecordSpan { (rowid, span) throws(DBError) -> Bool in
      let record = unsafe Self.bindSpan(span, to: resolver)
      return try body(
        RowView(rowid: rowid, definition: definition, span: record, coveringIncludes: covering))
    }
  }

  /// Re-expresses a record pointer (valid for the current snapshot) as a
  /// `RawSpan` whose lifetime is tied to the resolver that owns the mapping.
  /// The page memory stays valid as long as the snapshot does; binding the
  /// span there is what lets the compiler reject a view that escapes it.
  @_lifetime(borrow resolver)
  static func bindSpan(_ bytes: UnsafeRawBufferPointer, to resolver: borrowing R) -> RawSpan {
    let span = unsafe RawSpan(_unsafeBytes: bytes)
    return unsafe _overrideLifetime(span, borrowing: resolver)
  }

  /// The next fully materialized row, or nil at the end of the bounds.
  public mutating func next() throws(DBError) -> Row? {
    guard let (rowid, recordBytes) = try nextRecord() else { return nil }
    let values = try Relation.materializeRow(
      table: table, rowid: rowid, recordBytes: recordBytes)
    return Row(
      rowid: rowid, names: table.definition.columns.map(\.name), values: values)
  }
}

extension Relation {
  /// (lower inclusive, upper exclusive) raw-key bounds for an index scan.
  static func scanBounds(
    _ bounds: IndexBounds, index: Catalog.IndexRecord, table: Catalog.TableRecord
  ) throws(DBError) -> (lower: [UInt8]?, upper: [UInt8]?) {
    let collations = indexCollations(index.definition, table: table.definition)
    func encodePrefix(_ values: [Value]) throws(DBError) -> [UInt8] {
      guard values.count <= collations.count else {
        throw DBError.invalidDefinition(
          "bounds use \(values.count) columns; index \(index.definition.name) has \(collations.count)")
      }
      return try KeyCodec.encode(values, collations: Array(collations.prefix(values.count)))
    }
    switch bounds {
    case .all:
      return (nil, nil)
    case .prefix(let values):
      let lower = try encodePrefix(values)
      return (lower, KeyCodec.prefixSuccessor(lower))
    case .range(let lower, let upper, let lowerOpen, let upperOpen):
      var lowerKey: [UInt8]?
      if let lower {
        let encoded = try encodePrefix(lower)
        lowerKey = lowerOpen ? KeyCodec.prefixSuccessor(encoded) : encoded
      }
      var upperKey: [UInt8]?
      if let upper {
        let encoded = try encodePrefix(upper)
        upperKey = upperOpen ? encoded : KeyCodec.prefixSuccessor(encoded)
      }
      return (lowerKey, upperKey)
    }
  }

  static func readRow(
    _ resolver: some PageResolver, table: Catalog.TableRecord, rowid: Int64
  ) throws(DBError) -> Row? {
    guard let bytes = try getBytes(resolver, table.handle, key: KeyCodec.rowKey(rowid)) else {
      return nil
    }
    let values = try materializeRow(table: table, rowid: rowid, recordBytes: bytes)
    return Row(rowid: rowid, names: table.definition.columns.map(\.name), values: values)
  }

  static func firstRowid(
    _ resolver: some PageResolver, index: Catalog.IndexRecord, table: Catalog.TableRecord,
    equals values: [Value]
  ) throws(DBError) -> Int64? {
    let collations = indexCollations(index.definition, table: table.definition)
    guard values.count == collations.count else {
      throw DBError.invalidDefinition(
        "firstRowid needs all \(collations.count) columns of \(index.definition.name)")
    }
    let prefix = try KeyCodec.encode(values, collations: collations)
    var cursor = Cursor(resolver: resolver, tree: index.handle)
    var outcome: Result<Int64?, DBError> = .success(nil)
    prefix.withUnsafeBytes { raw in
      do throws(DBError) {
        _ = unsafe try cursor.seek(raw)
        guard cursor.isValid else { return }
        let hit: Int64?? = unsafe try cursor.withCurrent { (key, _) throws(DBError) in
          guard key.count == prefix.count + 8,
            prefix.withUnsafeBytes({ p in
              unsafe key.prefix(prefix.count).elementsEqual(UnsafeRawBufferPointer(rebasing: p[...]))
            })
          else { return nil }
          return unsafe KeyCodec.rowid(fromSuffixOf: key)
        }
        outcome = .success(hit ?? nil)
      } catch {
        outcome = .failure(error)
      }
    }
    return try outcome.get()
  }
}

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
  var cursor: Cursor<R>
  var exhausted = false

  init(
    resolver: R, table: Catalog.TableRecord, mode: Mode,
    lowerKey: [UInt8]?, upperKey: [UInt8]?
  ) throws(DBError) {
    self.resolver = resolver
    self.table = table
    self.mode = mode
    self.upperKey = upperKey
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
          _ = try cursor.seek(raw)
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
    let entry: (rowid: Int64, record: [UInt8]?)? = try cursor.withCurrent {
      (key, ref) throws(DBError) in
      if let upperKey {
        let inBounds = upperKey.withUnsafeBytes { upper in
          Node.compare(key, UnsafeRawBufferPointer(rebasing: upper[...])) < 0
        }
        guard inBounds else { return nil }
      }
      guard let rowid = KeyCodec.rowid(fromSuffixOf: key) else {
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
    while !exhausted {
      let step: Bool? = try cursor.withCurrent { (key, ref) throws(DBError) -> Bool? in
        if let upperKey {
          let inBounds = upperKey.withUnsafeBytes { upper in
            Node.compare(key, UnsafeRawBufferPointer(rebasing: upper[...])) < 0
          }
          guard inBounds else { return nil }  // past the upper bound: stop
        }
        guard let rowid = KeyCodec.rowid(fromSuffixOf: key) else {
          throw DBError.integrityFailure("malformed key in \(table.definition.name)")
        }
        switch mode {
        case .table:
          return try BTree.withValueBytes(ref, resolver: resolver) { span throws(DBError) in
            try body(rowid, span)
          }
        case .index:
          let proceed: Bool? = try Relation.withRowValue(
            resolver, table.handle, key: KeyCodec.rowKey(rowid)
          ) { rowRef throws(DBError) in
            try BTree.withValueBytes(rowRef, resolver: resolver) { span throws(DBError) in
              try body(rowid, span)
            }
          }
          guard let proceed else {
            throw DBError.integrityFailure(
              "dangling index entry: \(table.definition.name) rowid \(rowid)")
          }
          return proceed
        }
      } ?? nil

      guard let proceed = step else {
        exhausted = true  // cursor invalid or past the bound
        return
      }
      if !proceed { return }  // body requested early-exit
      exhausted = !(try cursor.next())
    }
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
        _ = try cursor.seek(raw)
        guard cursor.isValid else { return }
        let hit: Int64?? = try cursor.withCurrent { (key, _) throws(DBError) in
          guard key.count == prefix.count + 8,
            prefix.withUnsafeBytes({ p in
              key.prefix(prefix.count).elementsEqual(UnsafeRawBufferPointer(rebasing: p[...]))
            })
          else { return nil }
          return KeyCodec.rowid(fromSuffixOf: key)
        }
        outcome = .success(hit ?? nil)
      } catch {
        outcome = .failure(error)
      }
    }
    return try outcome.get()
  }
}

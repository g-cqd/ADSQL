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

  /// The next row, or nil at the end of the bounds.
  public mutating func next() throws(DBError) -> Row? {
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
    let values = try Relation.materializeRow(
      table: table, rowid: entry.rowid, recordBytes: recordBytes)
    exhausted = !(try cursor.next())
    return Row(
      rowid: entry.rowid, names: table.definition.columns.map(\.name), values: values)
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

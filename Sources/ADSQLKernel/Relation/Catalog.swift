/// Catalog persistence: system rows in the main tree under the reserved
/// 0x00 prefix.
///
///   00 76                  → version row: catalogVersion u64 LE ||
///                            nextTableId u32 LE || nextIndexId u32 LE
///   00 74 <tableName>      → TableRecord
///   00 69 <indexName>      → IndexRecord
///   00 71 <tableId u32 BE> → AUTOINCREMENT high-water u64 LE
///
/// Tree roots move on every COW commit, so records embed their TreeHandle
/// and `Relation.serializeState` rewrites changed records at commit time.
enum Catalog {
  static let prefix: UInt8 = 0x00
  static let kindVersion: UInt8 = 0x76 // 'v'
  static let kindTable: UInt8 = 0x74 // 't'
  static let kindIndex: UInt8 = 0x69 // 'i'
  static let kindSequence: UInt8 = 0x71 // 'q'
  static let kindFTS: UInt8 = 0x66 // 'f' — FTS virtual-table record (M5/F0)

  // MARK: - Keys

  static let versionKey: [UInt8] = [prefix, kindVersion]

  static func tableKey(_ name: String) -> [UInt8] {
    [prefix, kindTable] + Array(name.utf8)
  }

  static func indexKey(_ name: String) -> [UInt8] {
    [prefix, kindIndex] + Array(name.utf8)
  }

  static func sequenceKey(_ tableId: UInt32) -> [UInt8] {
    var key: [UInt8] = [prefix, kindSequence]
    withUnsafeBytes(of: tableId.bigEndian) { unsafe key.append(contentsOf: $0) }
    return key
  }

  static func ftsKey(_ name: String) -> [UInt8] {
    [prefix, kindFTS] + Array(name.utf8)
  }

  /// (lower, upper) bounds for scanning all keys of one kind.
  static func kindBounds(_ kind: UInt8) -> (lower: [UInt8], upper: [UInt8]) {
    ([prefix, kind], [prefix, kind + 1])
  }

  // MARK: - Version row

  struct VersionRow: Equatable, Sendable {
    var catalogVersion: UInt64 = 0
    var nextTableId: UInt32 = 1
    var nextIndexId: UInt32 = 1
  }

  static func encode(_ version: VersionRow) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(16)
    withUnsafeBytes(of: version.catalogVersion.littleEndian) { unsafe out.append(contentsOf: $0) }
    withUnsafeBytes(of: version.nextTableId.littleEndian) { unsafe out.append(contentsOf: $0) }
    withUnsafeBytes(of: version.nextIndexId.littleEndian) { unsafe out.append(contentsOf: $0) }
    return out
  }

  static func decodeVersion(_ bytes: UnsafeRawBufferPointer) throws(DBError) -> VersionRow {
    guard bytes.count >= 16 else { throw DBError.integrityFailure("catalog version row too short") }
    return unsafe VersionRow(
      catalogVersion: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
      nextTableId: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
      nextIndexId: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
  }

  // MARK: - Records

  struct TableRecord: Equatable, Sendable {
    var tableId: UInt32
    var handle: TreeHandle
    var definition: TableDefinition
  }

  struct IndexRecord: Equatable, Sendable {
    var indexId: UInt32
    var tableId: UInt32
    var handle: TreeHandle
    var definition: IndexDefinition
  }

  /// An FTS virtual table: its config plus the three B+trees it owns (term
  /// dictionary, postings, doc/field stats). Roots are `.empty` until F2 writes
  /// the first posting; `serializeState` rewrites the record when any moves.
  struct FTSRecord: Equatable, Sendable {
    var ftsId: UInt32
    var dict: TreeHandle
    var postings: TreeHandle
    var stats: TreeHandle
    var definition: FTSDefinition
  }

  private static let recordVersion: UInt8 = 1

  private static func appendName(_ name: String, to out: inout [UInt8]) {
    let utf8 = Array(name.utf8)
    precondition(utf8.count <= 255, "names are validated to ≤255 bytes")
    out.append(UInt8(utf8.count))
    out.append(contentsOf: utf8)
  }

  private static func readName(
    _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) -> String {
    guard offset < bytes.count else { throw DBError.integrityFailure("catalog: truncated name") }
    let length = unsafe Int(bytes[offset])
    offset += 1
    guard offset + length <= bytes.count else {
      throw DBError.integrityFailure("catalog: truncated name body")
    }
    let name = unsafe String(decoding: bytes[offset..<offset + length], as: UTF8.self)
    offset += length
    return name
  }

  private static func appendHandle(_ handle: TreeHandle, to out: inout [UInt8]) {
    withUnsafeBytes(of: handle.rootPage.littleEndian) { unsafe out.append(contentsOf: $0) }
    withUnsafeBytes(of: handle.depth.littleEndian) { unsafe out.append(contentsOf: $0) }
    withUnsafeBytes(of: handle.count.littleEndian) { unsafe out.append(contentsOf: $0) }
  }

  private static func readHandle(
    _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) -> TreeHandle {
    guard offset + 18 <= bytes.count else {
      throw DBError.integrityFailure("catalog: truncated tree handle")
    }
    let handle = unsafe TreeHandle(
      rootPage: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)),
      depth: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self)),
      count: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 10, as: UInt64.self)))
    offset += 18
    return handle
  }

  // TableRecord layout:
  //   u8 recVersion || u32 LE tableId || handle(18) || u8 tableFlags
  //   || u16 LE columnCount || columns || u8 pkKind (0 implicit, 1 alias)
  //   || [alias: name + u8 autoincrement] || u8 fkCount || fks
  // Column: name || u8 type || u8 flags(bit0 notNull, bit1 nocase)
  //   || u8 defaultKind (0 none,1 null,2 int,3 real,4 text,5 blob,6 now) || payload
  // FK: u8 colCount || names || parentName || u8 action

  static func encode(_ record: TableRecord) -> [UInt8] {
    var out: [UInt8] = [recordVersion]
    withUnsafeBytes(of: record.tableId.littleEndian) { unsafe out.append(contentsOf: $0) }
    appendHandle(record.handle, to: &out)
    out.append(0) // tableFlags reserved
    let definition = record.definition
    withUnsafeBytes(of: UInt16(definition.columns.count).littleEndian) {
      unsafe out.append(contentsOf: $0)
    }
    for column in definition.columns {
      appendName(column.name, to: &out)
      out.append(column.type.rawValue)
      var flags: UInt8 = 0
      if column.notNull { flags |= 1 }
      if column.collation == .nocase { flags |= 2 }
      out.append(flags)
      switch column.defaultValue {
      case nil:
        out.append(0)
      case .value(.null):
        out.append(1)
      case .value(.integer(let v)):
        out.append(2)
        Varint.append(Varint.zigzag(v), to: &out)
      case .value(.real(let d)):
        out.append(3)
        withUnsafeBytes(of: d.bitPattern.littleEndian) { unsafe out.append(contentsOf: $0) }
      case .value(.text(let s)):
        out.append(4)
        let utf8 = Array(s.utf8)
        withUnsafeBytes(of: UInt16(utf8.count).littleEndian) { unsafe out.append(contentsOf: $0) }
        out.append(contentsOf: utf8)
      case .value(.blob(let b)):
        out.append(5)
        withUnsafeBytes(of: UInt16(b.count).littleEndian) { unsafe out.append(contentsOf: $0) }
        out.append(contentsOf: b)
      case .datetimeNow:
        out.append(6)
      }
    }
    switch definition.primaryKey {
    case .implicitRowid:
      out.append(0)
    case .rowidAlias(let column, let autoincrement):
      out.append(1)
      appendName(column, to: &out)
      out.append(autoincrement ? 1 : 0)
    }
    out.append(UInt8(definition.foreignKeys.count))
    for fk in definition.foreignKeys {
      out.append(UInt8(fk.childColumns.count))
      for column in fk.childColumns { appendName(column, to: &out) }
      appendName(fk.parentTable, to: &out)
      out.append(fk.onDelete.rawValue)
    }
    return out
  }

  static func decodeTable(
    _ bytes: UnsafeRawBufferPointer, name: String
  ) throws(DBError) -> TableRecord {
    var offset = 0
    guard bytes.count >= 1, unsafe bytes[0] == recordVersion else {
      throw DBError.integrityFailure("catalog: bad table record version")
    }
    offset = 1
    guard offset + 4 <= bytes.count else {
      throw DBError.integrityFailure("catalog: truncated table id")
    }
    let tableId = unsafe UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    offset += 4
    let handle = unsafe try readHandle(bytes, &offset)
    guard offset < bytes.count else { throw DBError.integrityFailure("catalog: truncated flags") }
    offset += 1 // tableFlags
    guard offset + 2 <= bytes.count else {
      throw DBError.integrityFailure("catalog: truncated column count")
    }
    let columnCount = unsafe Int(
      UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
    offset += 2

    var columns: [ColumnDefinition] = []
    columns.reserveCapacity(columnCount)
    for _ in 0..<columnCount {
      let columnName = unsafe try readName(bytes, &offset)
      guard offset + 3 <= bytes.count else {
        throw DBError.integrityFailure("catalog: truncated column")
      }
      guard let type = unsafe ColumnType(rawValue: bytes[offset]) else {
        throw DBError.integrityFailure("catalog: unknown column type")
      }
      let flags = unsafe bytes[offset + 1]
      let defaultKind = unsafe bytes[offset + 2]
      offset += 3
      var defaultValue: DefaultValue?
      switch defaultKind {
      case 0:
        defaultValue = nil
      case 1:
        defaultValue = .value(.null)
      case 2:
        guard let raw = unsafe Varint.read(bytes, &offset) else {
          throw DBError.integrityFailure("catalog: truncated default int")
        }
        defaultValue = .value(.integer(Varint.unzigzag(raw)))
      case 3:
        guard offset + 8 <= bytes.count else {
          throw DBError.integrityFailure("catalog: truncated default real")
        }
        let bits = unsafe UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        offset += 8
        defaultValue = .value(.real(Double(bitPattern: bits)))
      case 4, 5:
        guard offset + 2 <= bytes.count else {
          throw DBError.integrityFailure("catalog: truncated default length")
        }
        let length = unsafe Int(
          UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
        offset += 2
        guard offset + length <= bytes.count else {
          throw DBError.integrityFailure("catalog: truncated default body")
        }
        let payload = unsafe bytes[offset..<offset + length]
        offset += length
        defaultValue = unsafe defaultKind == 4
          ? .value(.text(String(decoding: payload, as: UTF8.self)))
          : .value(.blob([UInt8](payload)))
      case 6:
        defaultValue = .datetimeNow
      default:
        throw DBError.integrityFailure("catalog: unknown default kind")
      }
      columns.append(
        ColumnDefinition(
          columnName, type, notNull: flags & 1 != 0,
          collation: flags & 2 != 0 ? .nocase : .binary,
          defaultValue: defaultValue))
    }

    guard offset < bytes.count else { throw DBError.integrityFailure("catalog: truncated pk") }
    let pkKind = unsafe bytes[offset]
    offset += 1
    let primaryKey: PrimaryKey
    switch pkKind {
    case 0:
      primaryKey = .implicitRowid
    case 1:
      let column = unsafe try readName(bytes, &offset)
      guard offset < bytes.count else {
        throw DBError.integrityFailure("catalog: truncated autoincrement flag")
      }
      let autoincrement = unsafe bytes[offset] != 0
      offset += 1
      primaryKey = .rowidAlias(column: column, autoincrement: autoincrement)
    default:
      throw DBError.integrityFailure("catalog: unknown pk kind")
    }

    guard offset < bytes.count else { throw DBError.integrityFailure("catalog: truncated fk count") }
    let fkCount = unsafe Int(bytes[offset])
    offset += 1
    var foreignKeys: [ForeignKey] = []
    for _ in 0..<fkCount {
      guard offset < bytes.count else {
        throw DBError.integrityFailure("catalog: truncated fk")
      }
      let colCount = unsafe Int(bytes[offset])
      offset += 1
      var childColumns: [String] = []
      for _ in 0..<colCount { unsafe childColumns.append(try readName(bytes, &offset)) }
      let parent = unsafe try readName(bytes, &offset)
      guard offset < bytes.count, let action = unsafe FKAction(rawValue: bytes[offset]) else {
        throw DBError.integrityFailure("catalog: bad fk action")
      }
      offset += 1
      foreignKeys.append(
        ForeignKey(childColumns: childColumns, parentTable: parent, onDelete: action))
    }

    return TableRecord(
      tableId: tableId, handle: handle,
      definition: TableDefinition(
        name, columns: columns, primaryKey: primaryKey, foreignKeys: foreignKeys))
  }

  // IndexRecord layout (self-contained: single-record fetches need no scan):
  //   u8 recVersion || u32 LE indexId || u32 LE tableId || handle(18)
  //   || u8 idxFlags(bit0 unique) || tableName || u8 colCount || column names

  static func encode(_ record: IndexRecord) -> [UInt8] {
    var out: [UInt8] = [recordVersion]
    withUnsafeBytes(of: record.indexId.littleEndian) { unsafe out.append(contentsOf: $0) }
    withUnsafeBytes(of: record.tableId.littleEndian) { unsafe out.append(contentsOf: $0) }
    appendHandle(record.handle, to: &out)
    out.append(record.definition.unique ? 1 : 0)
    appendName(record.definition.table, to: &out)
    out.append(UInt8(record.definition.columns.count))
    for column in record.definition.columns { appendName(column, to: &out) }
    return out
  }

  static func decodeIndex(
    _ bytes: UnsafeRawBufferPointer, name: String
  ) throws(DBError) -> IndexRecord {
    var offset = 0
    guard bytes.count >= 1, unsafe bytes[0] == recordVersion else {
      throw DBError.integrityFailure("catalog: bad index record version")
    }
    offset = 1
    guard offset + 8 <= bytes.count else {
      throw DBError.integrityFailure("catalog: truncated index ids")
    }
    let indexId = unsafe UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    let tableId = unsafe UInt32(
      littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
    offset += 8
    let handle = unsafe try readHandle(bytes, &offset)
    guard offset < bytes.count else {
      throw DBError.integrityFailure("catalog: truncated index flags")
    }
    let unique = unsafe bytes[offset] & 1 != 0
    offset += 1
    let table = unsafe try readName(bytes, &offset)
    guard offset < bytes.count else {
      throw DBError.integrityFailure("catalog: truncated index column count")
    }
    let colCount = unsafe Int(bytes[offset])
    offset += 1
    var columns: [String] = []
    for _ in 0..<colCount { unsafe columns.append(try readName(bytes, &offset)) }
    return IndexRecord(
      indexId: indexId, tableId: tableId, handle: handle,
      definition: IndexDefinition(name, on: table, columns: columns, unique: unique))
  }

  // FTSRecord layout:
  //   u8 recVersion || u32 LE ftsId || dict(18) || postings(18) || stats(18)
  //   || u16 LE colCount || column names
  //   || u8 tokenizeCount || tokenize tokens
  //   || u8 contentKind (0 self, 1 external[+table+rowid], 2 contentless[+u8 del])
  //   || u8 prefixCount || prefix sizes (u8 each)
  //   || u8 detail (0 full, 1 column, 2 none) || u8 columnSize

  static func encode(_ record: FTSRecord) -> [UInt8] {
    var out: [UInt8] = [recordVersion]
    withUnsafeBytes(of: record.ftsId.littleEndian) { unsafe out.append(contentsOf: $0) }
    appendHandle(record.dict, to: &out)
    appendHandle(record.postings, to: &out)
    appendHandle(record.stats, to: &out)
    let definition = record.definition
    withUnsafeBytes(of: UInt16(definition.columns.count).littleEndian) {
      unsafe out.append(contentsOf: $0)
    }
    for column in definition.columns { appendName(column, to: &out) }
    out.append(UInt8(definition.tokenize.count))
    for token in definition.tokenize { appendName(token, to: &out) }
    switch definition.content {
    case .selfContained:
      out.append(0)
    case .external(let table, let rowid):
      out.append(1)
      appendName(table, to: &out)
      appendName(rowid, to: &out)
    case .contentless(let deleteEnabled):
      out.append(2)
      out.append(deleteEnabled ? 1 : 0)
    }
    out.append(UInt8(definition.prefix.count))
    for size in definition.prefix { out.append(UInt8(min(size, 255))) }
    switch definition.detail {
    case .full: out.append(0)
    case .column: out.append(1)
    case .none: out.append(2)
    }
    out.append(definition.columnSize ? 1 : 0)
    return out
  }

  static func decodeFTS(
    _ bytes: UnsafeRawBufferPointer, name: String
  ) throws(DBError) -> FTSRecord {
    var offset = 0
    guard bytes.count >= 1, unsafe bytes[0] == recordVersion else {
      throw DBError.integrityFailure("catalog: bad fts record version")
    }
    offset = 1
    guard offset + 4 <= bytes.count else {
      throw DBError.integrityFailure("catalog: truncated fts id")
    }
    let ftsId = unsafe UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    offset += 4
    let dict = unsafe try readHandle(bytes, &offset)
    let postings = unsafe try readHandle(bytes, &offset)
    let stats = unsafe try readHandle(bytes, &offset)
    guard offset + 2 <= bytes.count else {
      throw DBError.integrityFailure("catalog: truncated fts column count")
    }
    let columnCount = unsafe Int(
      UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
    offset += 2
    var columns: [String] = []
    columns.reserveCapacity(columnCount)
    for _ in 0..<columnCount { unsafe columns.append(try readName(bytes, &offset)) }

    guard offset < bytes.count else {
      throw DBError.integrityFailure("catalog: truncated fts tokenize count")
    }
    let tokenizeCount = unsafe Int(bytes[offset])
    offset += 1
    var tokenize: [String] = []
    for _ in 0..<tokenizeCount { unsafe tokenize.append(try readName(bytes, &offset)) }

    guard offset < bytes.count else {
      throw DBError.integrityFailure("catalog: truncated fts content kind")
    }
    let contentKind = unsafe bytes[offset]
    offset += 1
    let content: FTSContentMode
    switch contentKind {
    case 0:
      content = .selfContained
    case 1:
      let table = unsafe try readName(bytes, &offset)
      let rowid = unsafe try readName(bytes, &offset)
      content = .external(table: table, rowid: rowid)
    case 2:
      guard offset < bytes.count else {
        throw DBError.integrityFailure("catalog: truncated fts contentless flag")
      }
      let deleteEnabled = unsafe bytes[offset] != 0
      offset += 1
      content = .contentless(deleteEnabled: deleteEnabled)
    default:
      throw DBError.integrityFailure("catalog: unknown fts content kind")
    }

    guard offset < bytes.count else {
      throw DBError.integrityFailure("catalog: truncated fts prefix count")
    }
    let prefixCount = unsafe Int(bytes[offset])
    offset += 1
    var prefix: [Int] = []
    for _ in 0..<prefixCount {
      guard offset < bytes.count else {
        throw DBError.integrityFailure("catalog: truncated fts prefix")
      }
      unsafe prefix.append(Int(bytes[offset]))
      offset += 1
    }

    guard offset + 2 <= bytes.count else {
      throw DBError.integrityFailure("catalog: truncated fts detail/columnsize")
    }
    let detailRaw = unsafe bytes[offset]
    offset += 1
    let detail: FTSDetail
    switch detailRaw {
    case 0: detail = .full
    case 1: detail = .column
    case 2: detail = .none
    default: throw DBError.integrityFailure("catalog: unknown fts detail")
    }
    let columnSize = unsafe bytes[offset] != 0

    return FTSRecord(
      ftsId: ftsId, dict: dict, postings: postings, stats: stats,
      definition: FTSDefinition(
        name: name, columns: columns, tokenize: tokenize, content: content,
        prefix: prefix, detail: detail, columnSize: columnSize))
  }
}

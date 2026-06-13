/// Row record codec (table-tree values): varint column count followed by
/// sequential tagged cells. Rows whose stored count is below the schema's
/// column count read missing trailing columns as DEFAULT/NULL, which makes
/// a future ADD COLUMN free.
///
///   record = varint count || cell*
///   cell   = 00                       NULL
///          | 01 || zigzag varint      INTEGER
///          | 02 || 8B LE bitPattern   REAL
///          | 03 || varint len || utf8 TEXT
///          | 04 || varint len || raw  BLOB
public enum RecordCodec {
  enum CellTag {
    static let null: UInt8 = 0
    static let integer: UInt8 = 1
    static let real: UInt8 = 2
    static let text: UInt8 = 3
    static let blob: UInt8 = 4
  }

  public static func encode(_ values: [Value]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(16 + values.count * 8)
    Varint.append(UInt64(values.count), to: &out)
    for value in values {
      switch value {
      case .null:
        out.append(CellTag.null)
      case .integer(let v):
        out.append(CellTag.integer)
        Varint.append(Varint.zigzag(v), to: &out)
      case .real(let d):
        out.append(CellTag.real)
        withUnsafeBytes(of: d.bitPattern.littleEndian) { unsafe out.append(contentsOf: $0) }
      case .text(let s):
        out.append(CellTag.text)
        let utf8 = Array(s.utf8)
        Varint.append(UInt64(utf8.count), to: &out)
        out.append(contentsOf: utf8)
      case .blob(let b):
        out.append(CellTag.blob)
        Varint.append(UInt64(b.count), to: &out)
        out.append(contentsOf: b)
      }
    }
    return out
  }

  public static func decode(_ bytes: UnsafeRawBufferPointer) throws(DBError) -> [Value] {
    var offset = 0
    guard let rawCount = unsafe Varint.read(bytes, &offset), rawCount <= 4096 else {
      throw DBError.integrityFailure("row record: bad column count")
    }
    var values: [Value] = []
    values.reserveCapacity(Int(rawCount))
    for _ in 0..<rawCount {
      unsafe values.append(try decodeOne(bytes, &offset))
    }
    return values
  }

  /// Byte offset where each stored cell's tag begins, in column order.
  /// `offsets.count` is the row's stored column count (which may be below the
  /// schema's count: trailing columns read as DEFAULT/NULL). Allocates no
  /// strings, so it is cheap on the lazy-decode scan path.
  public static func cellOffsets(_ bytes: UnsafeRawBufferPointer) throws(DBError) -> [Int] {
    var offset = 0
    guard let rawCount = unsafe Varint.read(bytes, &offset), rawCount <= 4096 else {
      throw DBError.integrityFailure("row record: bad column count")
    }
    var offsets: [Int] = []
    offsets.reserveCapacity(Int(rawCount))
    for _ in 0..<rawCount {
      offsets.append(offset)
      unsafe try skipOne(bytes, &offset)
    }
    return offsets
  }

  /// Decodes the single cell whose tag begins at `start` (from `cellOffsets`).
  public static func decodeCell(
    _ bytes: UnsafeRawBufferPointer, at start: Int
  ) throws(DBError) -> Value {
    var offset = start
    return unsafe try decodeOne(bytes, &offset)
  }

  /// Decodes the column at `index` directly from a `RawSpan` record (the
  /// lifetime-checked scan path). `index` must be in range and must not be the
  /// rowid-alias column (the caller substitutes the rowid). Columns the row did
  /// not store read as their schema DEFAULT/NULL. The single point that bridges
  /// the safe `RawSpan` to the existing pointer-based decoder.
  public static func value(
    at index: Int, in span: RawSpan, defaults columns: [ColumnDefinition]
  ) throws(DBError) -> Value {
    try span.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) throws(DBError) -> Value in
      var offset = 0
      let stored = unsafe try readHeader(bytes, &offset)
      if index >= stored {
        switch columns[index].defaultValue {
        case .value(let v): return v
        case .datetimeNow, nil: return .null
        }
      }
      for _ in 0..<index { unsafe try skipCell(bytes, &offset) }
      return unsafe try decodeCell(bytes, at: offset)
    }
  }

  /// Reads the leading varint column count and advances `offset` to the first
  /// cell — the entry point for incremental, allocation-free column location.
  public static func readHeader(
    _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) -> Int {
    guard let rawCount = unsafe Varint.read(bytes, &offset), rawCount <= 4096 else {
      throw DBError.integrityFailure("row record: bad column count")
    }
    return Int(rawCount)
  }

  /// Advances `offset` past one cell without materializing its payload (used to
  /// walk to the i-th cell on the lazy scan path).
  public static func skipCell(
    _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) {
    unsafe try skipOne(bytes, &offset)
  }

  /// Decodes one tagged cell, advancing `offset` past it.
  private static func decodeOne(
    _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) -> Value {
    guard offset < bytes.count else {
      throw DBError.integrityFailure("row record: truncated cell")
    }
    let tag = unsafe bytes[offset]
    offset += 1
    switch tag {
    case CellTag.null:
      return .null
    case CellTag.integer:
      guard let raw = unsafe Varint.read(bytes, &offset) else {
        throw DBError.integrityFailure("row record: truncated integer")
      }
      return .integer(Varint.unzigzag(raw))
    case CellTag.real:
      guard offset + 8 <= bytes.count else {
        throw DBError.integrityFailure("row record: truncated real")
      }
      let bits = unsafe UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
      offset += 8
      return .real(Double(bitPattern: bits))
    case CellTag.text:
      guard let length = unsafe Varint.read(bytes, &offset), length <= UInt64(bytes.count - offset) else {
        throw DBError.integrityFailure("row record: truncated text")
      }
      let slice = unsafe bytes[offset..<offset + Int(length)]
      offset += Int(length)
      return unsafe .text(String(decoding: slice, as: UTF8.self))
    case CellTag.blob:
      guard let length = unsafe Varint.read(bytes, &offset), length <= UInt64(bytes.count - offset) else {
        throw DBError.integrityFailure("row record: truncated blob")
      }
      let value = unsafe Value.blob([UInt8](bytes[offset..<offset + Int(length)]))
      offset += Int(length)
      return value
    default:
      throw DBError.integrityFailure("row record: unknown cell tag \(tag)")
    }
  }

  /// Advances `offset` past one cell without materializing its payload.
  private static func skipOne(
    _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) {
    guard offset < bytes.count else {
      throw DBError.integrityFailure("row record: truncated cell")
    }
    let tag = unsafe bytes[offset]
    offset += 1
    switch tag {
    case CellTag.null:
      return
    case CellTag.integer:
      guard unsafe Varint.read(bytes, &offset) != nil else {
        throw DBError.integrityFailure("row record: truncated integer")
      }
    case CellTag.real:
      guard offset + 8 <= bytes.count else {
        throw DBError.integrityFailure("row record: truncated real")
      }
      offset += 8
    case CellTag.text, CellTag.blob:
      guard let length = unsafe Varint.read(bytes, &offset), length <= UInt64(bytes.count - offset) else {
        throw DBError.integrityFailure("row record: truncated cell payload")
      }
      offset += Int(length)
    default:
      throw DBError.integrityFailure("row record: unknown cell tag \(tag)")
    }
  }
}

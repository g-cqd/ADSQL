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
package enum RecordCodec {
  enum CellTag {
    static let null: UInt8 = 0
    static let integer: UInt8 = 1
    static let real: UInt8 = 2
    static let text: UInt8 = 3
    static let blob: UInt8 = 4
  }

  package static func encode(_ values: [Value]) -> [UInt8] {
    var out: [UInt8] = []
    encode(values, into: &out)
    return out
  }

  /// Encodes into a caller-owned buffer (cleared first, capacity kept) — lets the
  /// insert path reuse one scratch buffer across rows instead of allocating a
  /// fresh record per row.
  package static func encode(_ values: [Value], into out: inout [UInt8]) {
    out.removeAll(keepingCapacity: true)
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
        Varint.append(UInt64(s.utf8.count), to: &out)
        out.append(contentsOf: s.utf8)
      case .blob(let b):
        out.append(CellTag.blob)
        Varint.append(UInt64(b.count), to: &out)
        out.append(contentsOf: b)
      }
    }
  }

  package static func decode(_ bytes: UnsafeRawBufferPointer) throws(DBError) -> [Value] {
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
  package static func cellOffsets(_ bytes: UnsafeRawBufferPointer) throws(DBError) -> [Int] {
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
  package static func decodeCell(
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
  package static func value(
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

  /// Zero-copy access to the column at `index` when it is TEXT (`withText`) or
  /// BLOB (`withBlob`): `body` receives the payload bytes *in place* — no
  /// `String`/`[UInt8]` is materialized — valid only for the call. `body` gets
  /// `nil` when the column is NULL, is a different type, or the (short) row did
  /// not store it. Unlike `value(at:)` this does NOT apply a column DEFAULT for a
  /// missing column (callers needing default-aware reads use `value(at:)`).
  package static func withText<R>(
    at index: Int, in span: RawSpan,
    _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    unsafe try withPayload(at: index, in: span, expecting: CellTag.text, body)
  }

  package static func withBlob<R>(
    at index: Int, in span: RawSpan,
    _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    unsafe try withPayload(at: index, in: span, expecting: CellTag.blob, body)
  }

  private static func withPayload<R>(
    at index: Int, in span: RawSpan, expecting tag: UInt8,
    _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    try span.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) throws(DBError) -> R in
      unsafe try withPayload(at: index, in: bytes, expecting: tag, body)
    }
  }

  /// Pointer-based payload access — like the `RawSpan` overload but over an
  /// already-materialized byte buffer (the scan slot's stored span), skipping the
  /// `RawSpan` bridge. `body` gets the payload bytes in place, or nil when the
  /// column is NULL, a different storage class, or not stored by a short row.
  static func withPayload<R>(
    at index: Int, in bytes: UnsafeRawBufferPointer, expecting tag: UInt8,
    _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    var offset = 0
    let stored = unsafe try readHeader(bytes, &offset)
    guard index < stored else { return try body(nil) }
    for _ in 0..<index { unsafe try skipCell(bytes, &offset) }
    guard offset < bytes.count else {
      throw DBError.integrityFailure("row record: truncated cell")
    }
    guard unsafe bytes[offset] == tag else { return try body(nil) }
    offset += 1
    guard let length = unsafe Varint.read(bytes, &offset),
      length <= UInt64(bytes.count - offset)
    else {
      throw DBError.integrityFailure("row record: truncated cell payload")
    }
    let payload = unsafe UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + Int(length)])
    return unsafe try body(payload)
  }

  /// Zero-copy TEXT/BLOB access over a raw record buffer (the scan-slot span).
  static func withText<R>(
    at index: Int, in bytes: UnsafeRawBufferPointer,
    _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    unsafe try withPayload(at: index, in: bytes, expecting: CellTag.text, body)
  }

  static func withBlob<R>(
    at index: Int, in bytes: UnsafeRawBufferPointer,
    _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    unsafe try withPayload(at: index, in: bytes, expecting: CellTag.blob, body)
  }

  /// Reads the leading varint column count and advances `offset` to the first
  /// cell — the entry point for incremental, allocation-free column location.
  package static func readHeader(
    _ bytes: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) -> Int {
    guard let rawCount = unsafe Varint.read(bytes, &offset), rawCount <= 4096 else {
      throw DBError.integrityFailure("row record: bad column count")
    }
    return Int(rawCount)
  }

  /// Advances `offset` past one cell without materializing its payload (used to
  /// walk to the i-th cell on the lazy scan path).
  package static func skipCell(
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

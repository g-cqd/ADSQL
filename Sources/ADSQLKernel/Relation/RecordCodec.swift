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
        withUnsafeBytes(of: d.bitPattern.littleEndian) { out.append(contentsOf: $0) }
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
    guard let rawCount = Varint.read(bytes, &offset), rawCount <= 4096 else {
      throw DBError.integrityFailure("row record: bad column count")
    }
    var values: [Value] = []
    values.reserveCapacity(Int(rawCount))
    for _ in 0..<rawCount {
      guard offset < bytes.count else {
        throw DBError.integrityFailure("row record: truncated cell")
      }
      let tag = bytes[offset]
      offset += 1
      switch tag {
      case CellTag.null:
        values.append(.null)
      case CellTag.integer:
        guard let raw = Varint.read(bytes, &offset) else {
          throw DBError.integrityFailure("row record: truncated integer")
        }
        values.append(.integer(Varint.unzigzag(raw)))
      case CellTag.real:
        guard offset + 8 <= bytes.count else {
          throw DBError.integrityFailure("row record: truncated real")
        }
        let bits = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        offset += 8
        values.append(.real(Double(bitPattern: bits)))
      case CellTag.text:
        guard let length = Varint.read(bytes, &offset),
          length <= UInt64(bytes.count - offset)
        else {
          throw DBError.integrityFailure("row record: truncated text")
        }
        let slice = bytes[offset..<offset + Int(length)]
        values.append(.text(String(decoding: slice, as: UTF8.self)))
        offset += Int(length)
      case CellTag.blob:
        guard let length = Varint.read(bytes, &offset),
          length <= UInt64(bytes.count - offset)
        else {
          throw DBError.integrityFailure("row record: truncated blob")
        }
        values.append(.blob([UInt8](bytes[offset..<offset + Int(length)])))
        offset += Int(length)
      default:
        throw DBError.integrityFailure("row record: unknown cell tag \(tag)")
      }
    }
    return values
  }
}

/// Order-preserving key encoding: memcmp order over encoded bytes equals
/// `Value.keyOrder` over the typed values. Used for index keys and PK probes.
///
/// Grammar (tags chosen so storage classes sort NULL < INTEGER < REAL <
/// TEXT < BLOB, with gaps for a future unified-numeric tag):
///
///   NULL          : 05
///   INTEGER       : 10 || 8B BE of (bitPattern XOR 0x8000…)        (sign flip)
///   REAL          : 18 || 8B BE monotone(double)                   (-0 → +0)
///   TEXT binary   : 20 || escaped utf8 || 00
///   TEXT nocase   : 21 || escaped asciiFold(utf8) || 00
///   BLOB          : 28 || escaped bytes || 00
///
/// Escaping (FoundationDB tuple-layer scheme): every 0x00 payload byte
/// becomes 0x00 0xFF; the terminator is a bare 0x00. A terminated field
/// sorts before any extension of itself, and adjacent fields in composite
/// keys never bleed into each other.
///
/// Index entries append an 8-byte sign-biased big-endian rowid suffix.
/// Table-tree row keys are the bare 8-byte suffix (no tag).
public enum KeyCodec {
  public enum Tag {
    public static let null: UInt8 = 0x05
    public static let integer: UInt8 = 0x10
    public static let real: UInt8 = 0x18
    public static let text: UInt8 = 0x20
    public static let textNocase: UInt8 = 0x21
    public static let blob: UInt8 = 0x28
  }

  // MARK: - Values

  /// NaN must be normalized away (SQLite stores NaN as NULL) before encoding.
  public static func append(
    _ value: Value, collation: Collation, to key: inout [UInt8]
  ) throws(DBError) {
    switch value {
    case .null:
      key.append(Tag.null)
    case .integer(let v):
      key.append(Tag.integer)
      appendBE(UInt64(bitPattern: v) ^ 0x8000_0000_0000_0000, to: &key)
    case .real(let d):
      guard !d.isNaN else {
        throw DBError.invalidDefinition("NaN reached the key encoder (normalize to NULL first)")
      }
      key.append(Tag.real)
      appendBE(monotoneBits(d), to: &key)
    case .text(let s):
      if collation == .nocase {
        key.append(Tag.textNocase)
        appendEscaped(asciiFolded(Array(s.utf8)), to: &key)
      } else {
        key.append(Tag.text)
        appendEscaped(Array(s.utf8), to: &key)
      }
    case .blob(let b):
      key.append(Tag.blob)
      appendEscaped(b, to: &key)
    }
  }

  public static func encode(
    _ values: [Value], collations: [Collation]
  ) throws(DBError) -> [UInt8] {
    precondition(values.count == collations.count)
    var key: [UInt8] = []
    key.reserveCapacity(values.count * 12)
    for (value, collation) in zip(values, collations) {
      try append(value, collation: collation, to: &key)
    }
    return key
  }

  // MARK: - Rowids

  @inline(__always)
  static func biased(_ rowid: Int64) -> UInt64 {
    UInt64(bitPattern: rowid) ^ 0x8000_0000_0000_0000
  }

  /// Table-tree row key: bare 8-byte sign-biased big-endian rowid.
  public static func rowKey(_ rowid: Int64) -> [UInt8] {
    var key: [UInt8] = []
    key.reserveCapacity(8)
    appendBE(biased(rowid), to: &key)
    return key
  }

  public static func appendRowidSuffix(_ rowid: Int64, to key: inout [UInt8]) {
    appendBE(biased(rowid), to: &key)
  }

  /// Reads the trailing 8-byte rowid suffix of an index key (or a row key).
  public static func rowid(fromSuffixOf key: UnsafeRawBufferPointer) -> Int64? {
    guard key.count >= 8 else { return nil }
    var raw: UInt64 = 0
    for i in 0..<8 {
      raw = unsafe (raw << 8) | UInt64(key[key.count - 8 + i])
    }
    return Int64(bitPattern: raw ^ 0x8000_0000_0000_0000)
  }

  // MARK: - Range bounds

  /// Smallest byte string strictly greater than every key with `prefix`:
  /// rightmost non-0xFF byte incremented, tail truncated. nil = unbounded.
  public static func prefixSuccessor(_ prefix: [UInt8]) -> [UInt8]? {
    var out = prefix
    while let last = out.last {
      if last != 0xFF {
        out[out.count - 1] = last + 1
        return out
      }
      out.removeLast()
    }
    return nil
  }

  // MARK: - Primitives

  @inline(__always)
  static func appendBE(_ value: UInt64, to key: inout [UInt8]) {
    withUnsafeBytes(of: value.bigEndian) { unsafe key.append(contentsOf: $0) }
  }

  static func appendEscaped(_ bytes: [UInt8], to key: inout [UInt8]) {
    for byte in bytes {
      if byte == 0x00 {
        key.append(0x00)
        key.append(0xFF)
      } else {
        key.append(byte)
      }
    }
    key.append(0x00)
  }

  /// Monotone IEEE754 transform: positives get the sign bit set, negatives
  /// are bit-complemented; -0.0 normalizes to +0.0 first.
  @inline(__always)
  static func monotoneBits(_ d: Double) -> UInt64 {
    let normalized = d == 0 ? 0.0 : d
    let bits = normalized.bitPattern
    return (bits & 0x8000_0000_0000_0000) != 0 ? ~bits : bits | 0x8000_0000_0000_0000
  }

  /// SQLite NOCASE: ASCII A–Z only.
  @inline(__always)
  public static func asciiFolded(_ bytes: [UInt8]) -> [UInt8] {
    var out = bytes
    for i in out.indices where out[i] >= 0x41 && out[i] <= 0x5A {
      out[i] |= 0x20
    }
    return out
  }
}

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
package enum KeyCodec {
  package enum Tag {
    package static let null: UInt8 = 0x05
    package static let integer: UInt8 = 0x10
    package static let real: UInt8 = 0x18
    package static let text: UInt8 = 0x20
    package static let textNocase: UInt8 = 0x21
    package static let blob: UInt8 = 0x28
  }

  // MARK: - Values

  /// NaN must be normalized away (SQLite stores NaN as NULL) before encoding.
  package static func append(
    _ value: Value, collation: Collation, to key: inout [UInt8]
  ) throws(DBError) {
    switch value {
    case .null: appendNull(to: &key)
    case .integer(let v): appendInteger(v, to: &key)
    case .real(let d): try appendReal(d, to: &key)
    case .text(let s): appendTextBytes(s.utf8, collation: collation, to: &key)
    case .blob(let b): appendBlobBytes(b, to: &key)
    }
  }

  // Per-field encoders, factored out of `append` so the zero-copy index-probe
  // path (which encodes straight from a column's page bytes) emits byte-identical
  // keys. `append` is their only `Value`-dispatch wrapper; a property test locks
  // the equivalence.

  static func appendNull(to key: inout [UInt8]) { key.append(Tag.null) }

  static func appendInteger(_ value: Int64, to key: inout [UInt8]) {
    key.append(Tag.integer)
    appendBE(UInt64(bitPattern: value) ^ 0x8000_0000_0000_0000, to: &key)
  }

  static func appendReal(_ d: Double, to key: inout [UInt8]) throws(DBError) {
    guard !d.isNaN else {
      throw DBError.invalidDefinition("NaN reached the key encoder (normalize to NULL first)")
    }
    key.append(Tag.real)
    appendBE(monotoneBits(d), to: &key)
  }

  /// TEXT field from raw UTF-8 bytes, applying the NOCASE ASCII fold when
  /// `collation == .nocase` — identical output to `append(.text(...))`.
  static func appendTextBytes<S: Sequence>(
    _ bytes: S, collation: Collation, to key: inout [UInt8]
  ) where S.Element == UInt8 {
    if collation == .nocase {
      key.append(Tag.textNocase)
      appendEscaped(bytes.lazy.map(asciiFoldByte), to: &key)
    } else {
      key.append(Tag.text)
      appendEscaped(bytes, to: &key)
    }
  }

  static func appendBlobBytes<S: Sequence>(
    _ bytes: S, to key: inout [UInt8]
  ) where S.Element == UInt8 {
    key.append(Tag.blob)
    appendEscaped(bytes, to: &key)
  }

  package static func encode(
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

  // MARK: - Decoding (inverse of `append`, for index-only column reads)

  /// Decodes `columns` order-preserving fields from the start of `key` — the
  /// inverse of `append`. `key` must be exactly the encoded column bytes (the
  /// caller strips any trailing rowid suffix first: a field terminator `00`
  /// followed by a suffix byte `FF` would otherwise be misread as an escaped
  /// null). INTEGER / REAL / TEXT(binary) / BLOB / NULL round-trip losslessly
  /// (REAL normalizes -0.0 to +0.0, exactly as the encoder does). **NOCASE text
  /// was case-folded at encode time, so it decodes to its folded bytes, not the
  /// original** — callers needing the original must not decode a NOCASE column.
  package static func decode(
    _ key: UnsafeRawBufferPointer, columns: Int
  ) throws(DBError) -> [Value] {
    var values: [Value] = []
    values.reserveCapacity(columns)
    var offset = 0
    for _ in 0..<columns {
      values.append(unsafe try decodeField(key, &offset))
    }
    return values
  }

  private static func decodeField(
    _ key: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) -> Value {
    guard offset < key.count else { throw DBError.integrityFailure("key: truncated field") }
    let tag = unsafe key[offset]
    offset += 1
    switch tag {
    case Tag.null:
      return .null
    case Tag.integer:
      return .integer(Int64(bitPattern: unsafe try readBE(key, &offset) ^ 0x8000_0000_0000_0000))
    case Tag.real:
      // Invert `monotoneBits`: high bit set ⇒ originally non-negative (clear it);
      // else originally negative (bit-complement).
      let bits = unsafe try readBE(key, &offset)
      let original = (bits & 0x8000_0000_0000_0000) != 0 ? (bits & 0x7FFF_FFFF_FFFF_FFFF) : ~bits
      return .real(Double(bitPattern: original))
    case Tag.text, Tag.textNocase:
      return unsafe .text(String(decoding: try readEscaped(key, &offset), as: UTF8.self))
    case Tag.blob:
      return unsafe .blob(try readEscaped(key, &offset))
    default:
      throw DBError.integrityFailure("key: unknown field tag \(tag)")
    }
  }

  private static func readBE(
    _ key: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) -> UInt64 {
    guard offset + 8 <= key.count else { throw DBError.integrityFailure("key: truncated 8-byte field") }
    let raw = unsafe key.loadBE64(offset)
    offset += 8
    return raw
  }

  /// Reads one escaped field up to (and consuming) its bare 0x00 terminator,
  /// un-escaping `00 FF` back to `00`.
  private static func readEscaped(
    _ key: UnsafeRawBufferPointer, _ offset: inout Int
  ) throws(DBError) -> [UInt8] {
    var out: [UInt8] = []
    while offset < key.count {
      let byte = unsafe key[offset]
      offset += 1
      if byte != 0x00 {
        out.append(byte)
      } else if offset < key.count, unsafe key[offset] == 0xFF {
        out.append(0x00)  // escaped 0x00
        offset += 1
      } else {
        return out  // bare 0x00 terminator
      }
    }
    throw DBError.integrityFailure("key: unterminated escaped field")
  }

  // MARK: - Rowids

  @inline(__always)
  static func biased(_ rowid: Int64) -> UInt64 {
    UInt64(bitPattern: rowid) ^ 0x8000_0000_0000_0000
  }

  /// Table-tree row key: bare 8-byte sign-biased big-endian rowid.
  package static func rowKey(_ rowid: Int64) -> [UInt8] {
    var key: [UInt8] = []
    key.reserveCapacity(8)
    appendBE(biased(rowid), to: &key)
    return key
  }

  /// Writes the 8-byte row key into `buffer` (which must hold ≥ 8 bytes),
  /// avoiding the per-call `[UInt8]` allocation `rowKey` makes — used on the
  /// index-scan hot path where a row key is built per row only to seek the
  /// table tree.
  @inline(__always)
  package static func writeRowKey(_ rowid: Int64, into buffer: UnsafeMutableRawBufferPointer) {
    withUnsafeBytes(of: biased(rowid).bigEndian) { unsafe buffer.copyMemory(from: $0) }
  }

  package static func appendRowidSuffix(_ rowid: Int64, to key: inout [UInt8]) {
    appendBE(biased(rowid), to: &key)
  }

  /// Reads the trailing 8-byte rowid suffix of an index key (or a row key).
  package static func rowid(fromSuffixOf key: UnsafeRawBufferPointer) -> Int64? {
    guard key.count >= 8 else { return nil }
    let raw = unsafe key.loadBE64(key.count - 8)
    return Int64(bitPattern: raw ^ 0x8000_0000_0000_0000)
  }

  // MARK: - Range bounds

  /// Smallest byte string strictly greater than every key with `prefix`:
  /// rightmost non-0xFF byte incremented, tail truncated. nil = unbounded.
  package static func prefixSuccessor(_ prefix: [UInt8]) -> [UInt8]? {
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

  static func appendEscaped<S: Sequence>(
    _ bytes: S, to key: inout [UInt8]
  ) where S.Element == UInt8 {
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

  /// SQLite NOCASE fold of one byte (ASCII A–Z only).
  @inline(__always)
  static func asciiFoldByte(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b | 0x20 : b }

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
  package static func asciiFolded(_ bytes: [UInt8]) -> [UInt8] {
    var out = bytes
    for i in out.indices where out[i] >= 0x41 && out[i] <= 0x5A {
      out[i] |= 0x20
    }
    return out
  }
}

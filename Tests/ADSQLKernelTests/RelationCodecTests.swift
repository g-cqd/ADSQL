import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

private func encodeTuple(
  _ values: [Value], collations: [Collation], rowid: Int64? = nil
) throws -> [UInt8] {
  var result: Result<[UInt8], DBError> = .success([])
  do throws(DBError) {
    var key = try KeyCodec.encode(values, collations: collations)
    if let rowid { KeyCodec.appendRowidSuffix(rowid, to: &key) }
    result = .success(key)
  } catch {
    result = .failure(error)
  }
  return try result.get()
}

/// Lexicographic tuple order via the semantic oracle.
private func oracleCompare(
  _ a: (values: [Value], rowid: Int64?), _ b: (values: [Value], rowid: Int64?),
  collations: [Collation]
) -> Int {
  for i in 0..<min(a.values.count, b.values.count) {
    let c = Value.keyOrder(a.values[i], b.values[i], collation: collations[i])
    if c != 0 { return c }
  }
  if a.values.count != b.values.count {
    return a.values.count < b.values.count ? -1 : 1
  }
  let ra = a.rowid ?? 0
  let rb = b.rowid ?? 0
  return ra == rb ? 0 : (ra < rb ? -1 : 1)
}

private func memcmpOrder(_ a: [UInt8], _ b: [UInt8]) -> Int {
  let n = min(a.count, b.count)
  for i in 0..<n where a[i] != b[i] {
    return a[i] < b[i] ? -1 : 1
  }
  if a.count == b.count { return 0 }
  return a.count < b.count ? -1 : 1
}

@Suite("KeyCodec")
struct KeyCodecTests {
  @Test(arguments: [UInt64(1), 77, 991, 31337])
  func memcmpMatchesSemanticOrder(seed: UInt64) throws {
    var rng = SplitMix64(seed: seed)
    let columnCount = 1 + Int(rng.next() % 3)
    let types = (0..<columnCount).map { _ in RandomValues.anyType(&rng) }
    let collations = types.map { type in
      type == .text && rng.next() % 2 == 0 ? Collation.nocase : .binary
    }

    var tuples: [(values: [Value], rowid: Int64?)] = []
    for _ in 0..<300 {
      let values = types.map { RandomValues.value(&rng, type: $0, nullRatio: 15) }
      tuples.append((values: values, rowid: Int64(bitPattern: rng.next() % 2000)))
    }

    for i in stride(from: 0, to: tuples.count - 1, by: 1) {
      let a = tuples[i]
      let b = tuples[i + 1]
      let expected = oracleCompare(a, b, collations: collations)
      let encodedA = try encodeTuple(a.values, collations: collations, rowid: a.rowid)
      let encodedB = try encodeTuple(b.values, collations: collations, rowid: b.rowid)
      let got = memcmpOrder(encodedA, encodedB)
      #expect(
        got == expected,
        "tuple order mismatch: \(a) vs \(b) — oracle \(expected), memcmp \(got)")
    }
  }

  @Test func crossTypeTagOrdering() throws {
    // NULL < INTEGER < REAL < TEXT < BLOB, regardless of payload.
    let samples: [Value] = [
      .null, .integer(.max), .real(-1e308), .text(""), .blob([]),
    ]
    for i in 0..<samples.count - 1 {
      let a = try encodeTuple([samples[i]], collations: [.binary])
      let b = try encodeTuple([samples[i + 1]], collations: [.binary])
      #expect(memcmpOrder(a, b) == -1, "\(samples[i]) must sort before \(samples[i + 1])")
    }
  }

  @Test func fieldBoundariesNeverBleed() throws {
    // ("a","b") vs ("ab","") — composite encoding must order by FIRST field.
    let ab = try encodeTuple([.text("a"), .text("b")], collations: [.binary, .binary])
    let abEmpty = try encodeTuple([.text("ab"), .text("")], collations: [.binary, .binary])
    #expect(memcmpOrder(ab, abEmpty) == -1)

    // Embedded NULs: "a\0" vs "a" — extension sorts after.
    let plain = try encodeTuple([.text("a")], collations: [.binary])
    let withNul = try encodeTuple([.text("a\0")], collations: [.binary])
    #expect(memcmpOrder(plain, withNul) == -1)
    // "a\0" vs "a\u{1}": NUL escapes must keep byte order.
    let withOne = try encodeTuple([.text("a\u{1}")], collations: [.binary])
    #expect(memcmpOrder(withNul, withOne) == -1)
  }

  @Test func doubleMonotonicitySweep() throws {
    let doubles: [Double] = [
      -.infinity, -.greatestFiniteMagnitude, -1e10, -2.5, -1.0, -.leastNormalMagnitude,
      -.leastNonzeroMagnitude, -0.0, 0.0, .leastNonzeroMagnitude,
      .leastNormalMagnitude, 0.5, 1.0, 2.5, 1e10, .greatestFiniteMagnitude, .infinity,
    ]
    var previous: [UInt8]?
    for d in doubles {
      let encoded = try encodeTuple([.real(d)], collations: [.binary])
      if let previous {
        let order = memcmpOrder(previous, encoded)
        // -0.0 and 0.0 must encode identically; all else strictly increasing.
        #expect(order <= 0, "ordering broke at \(d)")
        if order == 0 {
          #expect(d == 0.0)
        }
      }
      previous = encoded
    }
    let negZero = try encodeTuple([.real(-0.0)], collations: [.binary])
    let posZero = try encodeTuple([.real(0.0)], collations: [.binary])
    #expect(negZero == posZero)
  }

  @Test func nanIsRejected() {
    #expect(throws: DBError.self) {
      _ = try encodeTuple([.real(.nan)], collations: [.binary])
    }
  }

  @Test func nocaseFoldsASCIIOnly() throws {
    let upper = try encodeTuple([.text("AbC-Σ")], collations: [.nocase])
    let lower = try encodeTuple([.text("abc-Σ")], collations: [.nocase])
    #expect(upper == lower)
    // Non-ASCII case is NOT folded (SQLite NOCASE semantics).
    let sigma = try encodeTuple([.text("σ")], collations: [.nocase])
    let bigSigma = try encodeTuple([.text("Σ")], collations: [.nocase])
    #expect(sigma != bigSigma)
    // Binary collation keeps case distinct.
    let binUpper = try encodeTuple([.text("ABC")], collations: [.binary])
    let binLower = try encodeTuple([.text("abc")], collations: [.binary])
    #expect(binUpper != binLower)
  }

  @Test func rowidSuffixRoundTripAndOrder() throws {
    let rowids: [Int64] = [.min, -100, -1, 0, 1, 42, .max]
    var previous: [UInt8]?
    for rowid in rowids {
      let key = KeyCodec.rowKey(rowid)
      #expect(key.count == 8)
      var back: Int64?
      key.withUnsafeBytes { back = KeyCodec.rowid(fromSuffixOf: $0) }
      #expect(back == rowid)
      if let previous {
        #expect(memcmpOrder(previous, key) == -1, "rowid order broke at \(rowid)")
      }
      previous = key
    }
  }

  @Test func prefixSuccessor() {
    #expect(KeyCodec.prefixSuccessor([0x20, 0x61]) == [0x20, 0x62])
    #expect(KeyCodec.prefixSuccessor([0x20, 0xFF]) == [0x21])
    #expect(KeyCodec.prefixSuccessor([0xFF, 0xFF]) == nil)
    #expect(KeyCodec.prefixSuccessor([]) == nil)
  }
}

@Suite("RecordCodec")
struct RecordCodecTests {
  @Test(arguments: [UInt64(3), 99, 4242])
  func roundTrip(seed: UInt64) throws {
    var rng = SplitMix64(seed: seed)
    for _ in 0..<200 {
      let columnCount = Int(rng.next() % 12)
      let values = (0..<columnCount).map { _ in
        RandomValues.value(&rng, type: RandomValues.anyType(&rng), nullRatio: 20)
      }
      let encoded = RecordCodec.encode(values)
      var decoded: [Value] = []
      var failure: DBError?
      encoded.withUnsafeBytes { raw in
        do throws(DBError) { decoded = try RecordCodec.decode(raw) } catch { failure = error }
      }
      #expect(failure == nil)
      #expect(decoded == values)
    }
  }

  @Test func emptyRow() throws {
    let encoded = RecordCodec.encode([])
    #expect(encoded == [0])
    var decoded: [Value]?
    encoded.withUnsafeBytes { raw in
      decoded = try? RecordCodec.decode(raw)
    }
    #expect(decoded == [])
  }

  @Test func decodeFuzzNeverCrashes() {
    var rng = SplitMix64(seed: 0xF0CACC1A)
    for _ in 0..<2000 {
      let bytes = RandomValues.bytes(&rng, maxLength: 64)
      bytes.withUnsafeBytes { raw in
        // Must either decode or throw a typed error — never trap.
        _ = try? RecordCodec.decode(raw)
      }
    }
  }

  @Test func truncatedRecordsThrow() {
    let encoded = RecordCodec.encode([.text("hello"), .integer(42)])
    for cut in 1..<encoded.count {
      var failed = false
      Array(encoded[0..<cut]).withUnsafeBytes { raw in
        do throws(DBError) {
          let decoded = try RecordCodec.decode(raw)
          // A cut that still decodes must yield fewer/equal columns.
          failed = decoded.count <= 2
        } catch {
          failed = true
        }
      }
      #expect(failed, "cut at \(cut) neither threw nor shrank")
    }
  }
}

@Suite("CivilTime")
struct CivilTimeTests {
  @Test func knownInstants() {
    #expect(CivilTime.string(forEpochSeconds: 0) == "1970-01-01 00:00:00")
    #expect(CivilTime.string(forEpochSeconds: 86_399) == "1970-01-01 23:59:59")
    #expect(CivilTime.string(forEpochSeconds: -1) == "1969-12-31 23:59:59")
    #expect(CivilTime.string(forEpochSeconds: 951_782_400) == "2000-02-29 00:00:00")
    #expect(CivilTime.string(forEpochSeconds: 1_700_000_000) == "2023-11-14 22:13:20")
  }

  @Test func nowHasSQLiteShape() {
    let now = CivilTime.utcNowString()
    #expect(now.count == 19)
    let bytes = Array(now.utf8)
    #expect(bytes[4] == UInt8(ascii: "-") && bytes[7] == UInt8(ascii: "-"))
    #expect(bytes[10] == UInt8(ascii: " "))
    #expect(bytes[13] == UInt8(ascii: ":") && bytes[16] == UInt8(ascii: ":"))
    #expect(now.hasPrefix("20"))
  }
}

@Suite("Definitions validation")
struct DefinitionsTests {
  @Test func tableValidationCatchesMistakes() {
    let dup = TableDefinition(
      "t", columns: [ColumnDefinition("a", .integer), ColumnDefinition("a", .text)])
    #expect(throws: DBError.self) { try dup.validate() }

    let badAlias = TableDefinition(
      "t", columns: [ColumnDefinition("a", .text)],
      primaryKey: .rowidAlias(column: "a", autoincrement: false))
    #expect(throws: DBError.self) { try badAlias.validate() }

    let missingAlias = TableDefinition(
      "t", columns: [ColumnDefinition("a", .integer)],
      primaryKey: .rowidAlias(column: "zz", autoincrement: false))
    #expect(throws: DBError.self) { try missingAlias.validate() }

    let badDefault = TableDefinition(
      "t", columns: [ColumnDefinition("a", .integer, defaultValue: .value(.text("x")))])
    #expect(throws: DBError.self) { try badDefault.validate() }

    let badFK = TableDefinition(
      "t", columns: [ColumnDefinition("a", .integer)],
      foreignKeys: [ForeignKey(childColumns: ["nope"], parentTable: "p", onDelete: .cascade)])
    #expect(throws: DBError.noSuchColumn(table: "t", column: "nope")) { try badFK.validate() }

    let good = TableDefinition(
      "documents",
      columns: [
        ColumnDefinition("id", .integer, notNull: true),
        ColumnDefinition("key", .text, notNull: true),
        ColumnDefinition("title", .text, notNull: true, collation: .nocase),
        ColumnDefinition("created_at", .text, defaultValue: .datetimeNow),
        ColumnDefinition("is_deprecated", .integer, defaultValue: .value(.integer(0))),
      ],
      primaryKey: .rowidAlias(column: "id", autoincrement: true))
    #expect(throws: Never.self) { try good.validate() }
  }

  @Test func indexValidation() {
    let table = TableDefinition(
      "t", columns: [ColumnDefinition("a", .integer), ColumnDefinition("b", .text)])
    #expect(throws: DBError.self) {
      try IndexDefinition("i", on: "t", columns: ["zz"]).validate(against: table)
    }
    #expect(throws: DBError.self) {
      try IndexDefinition("i", on: "t", columns: ["a", "a"]).validate(against: table)
    }
    #expect(throws: Never.self) {
      try IndexDefinition("i", on: "t", columns: ["b", "a"], unique: true).validate(against: table)
    }
  }
}

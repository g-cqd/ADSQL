/// A typed SQL value. Columns are STRICT: a column stores exactly its
/// declared type (or NULL when nullable); mismatches are typed errors, and
/// coercion exists only at explicit boundaries (CAST in M4, the importer).
public enum Value: Equatable, Sendable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob([UInt8])

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  /// Storage class, nil for NULL.
  public var columnType: ColumnType? {
    switch self {
    case .null: return nil
    case .integer: return .integer
    case .real: return .real
    case .text: return .text
    case .blob: return .blob
    }
  }

  var typeName: String {
    switch self {
    case .null: return "NULL"
    case .integer: return "INTEGER"
    case .real: return "REAL"
    case .text: return "TEXT"
    case .blob: return "BLOB"
    }
  }
}

public enum ColumnType: UInt8, Equatable, Sendable {
  case integer = 1
  case real = 2
  case text = 3
  case blob = 4

  var name: String {
    switch self {
    case .integer: return "INTEGER"
    case .real: return "REAL"
    case .text: return "TEXT"
    case .blob: return "BLOB"
    }
  }
}

public enum Collation: UInt8, Equatable, Sendable {
  case binary = 0
  /// SQLite NOCASE: ASCII A–Z fold only (not Unicode case folding).
  case nocase = 1
}

extension Value {
  /// Total order matching KeyCodec's encoding byte order exactly:
  /// NULL < INTEGER < REAL < TEXT < BLOB (storage classes never interleave
  /// under strict typing — a column compares within one class).
  /// Used as the test oracle and by deep integrity checks.
  public static func keyOrder(_ a: Value, _ b: Value, collation: Collation = .binary) -> Int {
    func rank(_ v: Value) -> Int {
      switch v {
      case .null: return 0
      case .integer: return 1
      case .real: return 2
      case .text: return 3
      case .blob: return 4
      }
    }
    let ra = rank(a)
    let rb = rank(b)
    if ra != rb { return ra < rb ? -1 : 1 }
    switch (a, b) {
    case (.null, .null):
      return 0
    case (.integer(let x), .integer(let y)):
      return x == y ? 0 : (x < y ? -1 : 1)
    case (.real(let x), .real(let y)):
      // Matches the monotone bit transform: -0.0 == +0.0; NaN never reaches
      // the codec (normalized to NULL upstream).
      if x == y { return 0 }
      return x < y ? -1 : 1
    case (.text(let x), .text(let y)):
      let xb = collation == .nocase ? KeyCodec.asciiFolded(Array(x.utf8)) : Array(x.utf8)
      let yb = collation == .nocase ? KeyCodec.asciiFolded(Array(y.utf8)) : Array(y.utf8)
      return compareBytes(xb, yb)
    case (.blob(let x), .blob(let y)):
      return compareBytes(x, y)
    default:
      preconditionFailure("ranks matched but cases differ")
    }
  }

  private static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
    let n = min(a.count, b.count)
    var i = 0
    while i < n {
      if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
      i += 1
    }
    if a.count == b.count { return 0 }
    return a.count < b.count ? -1 : 1
  }
}

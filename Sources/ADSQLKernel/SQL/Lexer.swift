/// SQL tokenizer: case-insensitive keywords, 'string' literals with ''
/// escapes, "quoted identifiers", integer/real/hex numerics, ?, $name and
/// :name parameters, -- and /* */ comments. Tokens carry byte offsets for
/// error spans.
struct SQLToken: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case keyword(String)        // uppercased
    case identifier(String)     // original case (bare or "quoted")
    case string(String)
    case blob([UInt8])          // x'hexdigits'
    case integer(Int64)
    case real(Double)
    /// Digit-only literal exceeding Int64 (sign may still rescue it:
    /// SQLite parses -9223372036854775808 as the exact Int64.min).
    case bigInteger(String)
    case parameter(SQLParam)
    case symbol(String)         // operators & punctuation
    case end
  }
  var kind: Kind
  var offset: Int
}

public enum SQLParam: Equatable, Hashable, Sendable {
  case positional(Int)          // 1-based
  case named(String)            // without sigil

  public var description: String {
    switch self {
    case .positional(let n): return "?\(n)"
    case .named(let name): return "$\(name)"
    }
  }
}

enum SQLLexer {
  static let keywords: Set<String> = [
    "SELECT", "FROM", "WHERE", "GROUP", "BY", "HAVING", "ORDER", "LIMIT",
    "OFFSET", "DISTINCT", "ALL", "UNION", "JOIN", "LEFT", "INNER", "OUTER",
    "CROSS", "ON", "AS", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE",
    "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "COLLATE", "ASC", "DESC",
    "INSERT", "INTO", "VALUES", "REPLACE", "IGNORE", "CONFLICT", "DO",
    "UPDATE", "SET", "DELETE", "RETURNING", "CREATE", "TABLE", "INDEX",
    "UNIQUE", "DROP", "IF", "EXISTS", "PRIMARY", "KEY", "AUTOINCREMENT",
    "DEFAULT", "CHECK", "FOREIGN", "REFERENCES", "CASCADE", "RESTRICT",
    "STRICT", "INTEGER", "INT", "TEXT", "REAL", "BLOB", "BEGIN", "COMMIT",
    "ROLLBACK", "TRANSACTION", "IMMEDIATE", "DEFERRED", "EXCLUSIVE",
    // Recognized so we can reject them with a named error:
    "WITH", "BETWEEN", "MATCH", "OVER", "WINDOW", "EXCEPT", "INTERSECT",
    "NATURAL", "RIGHT", "FULL", "USING", "GLOB", "REGEXP", "WITHOUT",
    "HAVING", "ESCAPE", "PRAGMA", "VACUUM", "EXPLAIN", "ALTER", "VIRTUAL",
    "TRIGGER", "VIEW", "ADD", "COLUMN", "RENAME", "TO",
    // CREATE TRIGGER grammar (M5/F5). Non-reserved in SQLite, so the parser
    // also lists them in `identifierKeywords` to keep them usable as names.
    "AFTER", "BEFORE", "INSTEAD", "FOR", "EACH", "ROW", "OF",
  ]

  static func tokenize(_ sql: String) throws(DBError) -> [SQLToken] {
    let bytes = Array(sql.utf8)
    var tokens: [SQLToken] = []
    var i = 0
    var positionalCount = 0

    func peek(_ ahead: Int = 0) -> UInt8? {
      i + ahead < bytes.count ? bytes[i + ahead] : nil
    }
    func isIdentStart(_ b: UInt8) -> Bool {
      (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }
    func isIdentBody(_ b: UInt8) -> Bool {
      isIdentStart(b) || (b >= 0x30 && b <= 0x39)
    }
    func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    while i < bytes.count {
      let start = i
      let b = bytes[i]

      // Whitespace
      if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
        i += 1
        continue
      }
      // -- comment
      if b == 0x2D, peek(1) == 0x2D {
        while i < bytes.count, bytes[i] != 0x0A { i += 1 }
        continue
      }
      // /* comment */
      if b == 0x2F, peek(1) == 0x2A {
        i += 2
        while i + 1 < bytes.count, !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
        guard i + 1 < bytes.count else {
          throw DBError.sqlSyntax(message: "unterminated comment", offset: start)
        }
        i += 2
        continue
      }
      // 'string'
      if b == 0x27 {
        i += 1
        var out: [UInt8] = []
        while true {
          guard i < bytes.count else {
            throw DBError.sqlSyntax(message: "unterminated string literal", offset: start)
          }
          if bytes[i] == 0x27 {
            if peek(1) == 0x27 {
              out.append(0x27)
              i += 2
            } else {
              i += 1
              break
            }
          } else {
            out.append(bytes[i])
            i += 1
          }
        }
        tokens.append(SQLToken(kind: .string(String(decoding: out, as: UTF8.self)), offset: start))
        continue
      }
      // "quoted identifier"
      if b == 0x22 {
        i += 1
        var out: [UInt8] = []
        while true {
          guard i < bytes.count else {
            throw DBError.sqlSyntax(message: "unterminated quoted identifier", offset: start)
          }
          if bytes[i] == 0x22 {
            if peek(1) == 0x22 {
              out.append(0x22)
              i += 2
            } else {
              i += 1
              break
            }
          } else {
            out.append(bytes[i])
            i += 1
          }
        }
        tokens.append(
          SQLToken(kind: .identifier(String(decoding: out, as: UTF8.self)), offset: start))
        continue
      }
      // Numbers (incl. .5, 0x1F)
      if isDigit(b) || (b == 0x2E && peek(1).map(isDigit) == true) {
        if b == 0x30, peek(1) == 0x78 || peek(1) == 0x58 {
          i += 2
          var value: UInt64 = 0
          let hexStart = i
          while let h = peek(), (isDigit(h) || (h | 0x20) >= 0x61 && (h | 0x20) <= 0x66) {
            let digit: UInt64 = isDigit(h) ? UInt64(h - 0x30) : UInt64((h | 0x20) - 0x61 + 10)
            value = value << 4 | digit
            i += 1
          }
          guard i > hexStart else {
            throw DBError.sqlSyntax(message: "malformed hex literal", offset: start)
          }
          tokens.append(SQLToken(kind: .integer(Int64(bitPattern: value)), offset: start))
          continue
        }
        var isReal = false
        var j = i
        while let d = j < bytes.count ? bytes[j] : nil, isDigit(d) { j += 1 }
        if j < bytes.count, bytes[j] == 0x2E {
          isReal = true
          j += 1
          while let d = j < bytes.count ? bytes[j] : nil, isDigit(d) { j += 1 }
        }
        if j < bytes.count, bytes[j] | 0x20 == 0x65 { // e/E exponent
          var k = j + 1
          if k < bytes.count, bytes[k] == 0x2B || bytes[k] == 0x2D { k += 1 }
          if k < bytes.count, isDigit(bytes[k]) {
            isReal = true
            j = k
            while let d = j < bytes.count ? bytes[j] : nil, isDigit(d) { j += 1 }
          }
        }
        let text = String(decoding: bytes[i..<j], as: UTF8.self)
        i = j
        if isReal {
          guard let d = Double(text) else {
            throw DBError.sqlSyntax(message: "malformed numeric literal", offset: start)
          }
          tokens.append(SQLToken(kind: .real(d), offset: start))
        } else if let v = Int64(text) {
          tokens.append(SQLToken(kind: .integer(v), offset: start))
        } else if Double(text) != nil { // integer literal overflowing i64
          tokens.append(SQLToken(kind: .bigInteger(text), offset: start))
        } else {
          throw DBError.sqlSyntax(message: "malformed numeric literal", offset: start)
        }
        continue
      }
      // x'hex' blob literal
      if (b | 0x20) == 0x78, peek(1) == 0x27 {
        i += 2
        var out: [UInt8] = []
        var pending: UInt8? = nil
        while true {
          guard let h = peek() else {
            throw DBError.sqlSyntax(message: "unterminated blob literal", offset: start)
          }
          if h == 0x27 {
            i += 1
            break
          }
          let digit: UInt8
          switch h {
          case 0x30...0x39: digit = h - 0x30
          case 0x41...0x46: digit = h - 0x41 + 10
          case 0x61...0x66: digit = h - 0x61 + 10
          default:
            throw DBError.sqlSyntax(message: "malformed blob literal", offset: start)
          }
          if let high = pending {
            out.append(high << 4 | digit)
            pending = nil
          } else {
            pending = digit
          }
          i += 1
        }
        guard pending == nil else {
          throw DBError.sqlSyntax(message: "odd-length blob literal", offset: start)
        }
        tokens.append(SQLToken(kind: .blob(out), offset: start))
        continue
      }
      // Identifiers / keywords
      if isIdentStart(b) {
        var j = i
        while j < bytes.count, isIdentBody(bytes[j]) { j += 1 }
        let text = String(decoding: bytes[i..<j], as: UTF8.self)
        i = j
        let upper = text.uppercased()
        if keywords.contains(upper) {
          tokens.append(SQLToken(kind: .keyword(upper), offset: start))
        } else {
          tokens.append(SQLToken(kind: .identifier(text), offset: start))
        }
        continue
      }
      // Parameters
      if b == 0x3F { // ?
        i += 1
        if let d = peek(), isDigit(d) {
          throw DBError.sqlUnsupported("?NNN positional parameters")
        }
        positionalCount += 1
        tokens.append(SQLToken(kind: .parameter(.positional(positionalCount)), offset: start))
        continue
      }
      if b == 0x24 || b == 0x3A { // $name :name
        i += 1
        var j = i
        while j < bytes.count, isIdentBody(bytes[j]) { j += 1 }
        guard j > i else {
          throw DBError.sqlSyntax(message: "parameter name expected", offset: start)
        }
        let name = String(decoding: bytes[i..<j], as: UTF8.self)
        i = j
        tokens.append(SQLToken(kind: .parameter(.named(name)), offset: start))
        continue
      }
      // Multi-char operators first
      func symbol(_ s: String) {
        tokens.append(SQLToken(kind: .symbol(s), offset: start))
        i += s.utf8.count
      }
      if b == 0x7C, peek(1) == 0x7C { symbol("||"); continue }
      if b == 0x3C, peek(1) == 0x3D { symbol("<="); continue }
      if b == 0x3E, peek(1) == 0x3D { symbol(">="); continue }
      if b == 0x3C, peek(1) == 0x3E { symbol("<>"); continue }
      if b == 0x21, peek(1) == 0x3D { symbol("!="); continue }
      if b == 0x3D, peek(1) == 0x3D { symbol("=="); continue }
      switch b {
      case 0x3D: symbol("=")
      case 0x3C: symbol("<")
      case 0x3E: symbol(">")
      case 0x2B: symbol("+")
      case 0x2D: symbol("-")
      case 0x2A: symbol("*")
      case 0x2F: symbol("/")
      case 0x25: symbol("%")
      case 0x28: symbol("(")
      case 0x29: symbol(")")
      case 0x2C: symbol(",")
      case 0x2E: symbol(".")
      case 0x3B: symbol(";")
      default:
        throw DBError.sqlSyntax(
          message: "unexpected character '\(Character(UnicodeScalar(b)))'", offset: start)
      }
    }
    tokens.append(SQLToken(kind: .end, offset: bytes.count))
    return tokens
  }
}

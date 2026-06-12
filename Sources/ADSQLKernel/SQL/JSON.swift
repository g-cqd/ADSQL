/// Minimal JSON support for json_extract and json_each: a strict
/// no-Foundation parser plus SQLite's value-mapping rules (JSON null → SQL
/// NULL, numbers → INTEGER/REAL, strings → TEXT, objects/arrays → their
/// JSON text).
enum SQLJSON {
  indirect enum Node: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case real(Double)
    case string(String)
    case array([Node])
    case object([(String, Node)])

    static func == (l: Node, r: Node) -> Bool {
      switch (l, r) {
      case (.null, .null): return true
      case (.bool(let a), .bool(let b)): return a == b
      case (.integer(let a), .integer(let b)): return a == b
      case (.real(let a), .real(let b)): return a == b
      case (.string(let a), .string(let b)): return a == b
      case (.array(let a), .array(let b)): return a == b
      case (.object(let a), .object(let b)):
        return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
      default: return false
      }
    }
  }

  // MARK: - Parsing

  static func parse(_ text: String) throws(DBError) -> Node {
    var parser = Parser(bytes: Array(text.utf8))
    let node = try parser.value()
    parser.skipWhitespace()
    guard parser.atEnd else { throw DBError.sqlRuntime("malformed JSON (trailing content)") }
    return node
  }

  struct Parser {
    let bytes: [UInt8]
    var i = 0

    var atEnd: Bool { i >= bytes.count }

    mutating func skipWhitespace() {
      while i < bytes.count,
        bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D {
        i += 1
      }
    }

    mutating func value() throws(DBError) -> Node {
      skipWhitespace()
      guard i < bytes.count else { throw DBError.sqlRuntime("malformed JSON (empty)") }
      switch bytes[i] {
      case 0x7B: return try object()
      case 0x5B: return try array()
      case 0x22: return .string(try string())
      case 0x74: // true
        try expect("true")
        return .bool(true)
      case 0x66: // false
        try expect("false")
        return .bool(false)
      case 0x6E: // null
        try expect("null")
        return .null
      default:
        return try number()
      }
    }

    mutating func expect(_ word: String) throws(DBError) {
      let w = Array(word.utf8)
      guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else {
        throw DBError.sqlRuntime("malformed JSON (expected \(word))")
      }
      i += w.count
    }

    mutating func object() throws(DBError) -> Node {
      i += 1 // {
      var members: [(String, Node)] = []
      skipWhitespace()
      if i < bytes.count, bytes[i] == 0x7D {
        i += 1
        return .object([])
      }
      while true {
        skipWhitespace()
        guard i < bytes.count, bytes[i] == 0x22 else {
          throw DBError.sqlRuntime("malformed JSON (object key)")
        }
        let key = try string()
        skipWhitespace()
        guard i < bytes.count, bytes[i] == 0x3A else {
          throw DBError.sqlRuntime("malformed JSON (expected :)")
        }
        i += 1
        members.append((key, try value()))
        skipWhitespace()
        guard i < bytes.count else { throw DBError.sqlRuntime("malformed JSON (unterminated object)") }
        if bytes[i] == 0x2C {
          i += 1
          continue
        }
        if bytes[i] == 0x7D {
          i += 1
          return .object(members)
        }
        throw DBError.sqlRuntime("malformed JSON (object separator)")
      }
    }

    mutating func array() throws(DBError) -> Node {
      i += 1 // [
      var items: [Node] = []
      skipWhitespace()
      if i < bytes.count, bytes[i] == 0x5D {
        i += 1
        return .array([])
      }
      while true {
        items.append(try value())
        skipWhitespace()
        guard i < bytes.count else { throw DBError.sqlRuntime("malformed JSON (unterminated array)") }
        if bytes[i] == 0x2C {
          i += 1
          continue
        }
        if bytes[i] == 0x5D {
          i += 1
          return .array(items)
        }
        throw DBError.sqlRuntime("malformed JSON (array separator)")
      }
    }

    mutating func string() throws(DBError) -> String {
      i += 1 // opening quote
      var out: [UInt8] = []
      while i < bytes.count {
        let b = bytes[i]
        if b == 0x22 {
          i += 1
          return String(decoding: out, as: UTF8.self)
        }
        if b == 0x5C { // backslash
          i += 1
          guard i < bytes.count else { break }
          switch bytes[i] {
          case 0x22: out.append(0x22)
          case 0x5C: out.append(0x5C)
          case 0x2F: out.append(0x2F)
          case 0x62: out.append(0x08)
          case 0x66: out.append(0x0C)
          case 0x6E: out.append(0x0A)
          case 0x72: out.append(0x0D)
          case 0x74: out.append(0x09)
          case 0x75: // \uXXXX (+ surrogate pairs)
            guard let scalar = try unicodeEscape() else {
              throw DBError.sqlRuntime("malformed JSON (\\u escape)")
            }
            out.append(contentsOf: Array(String(scalar).utf8))
            continue
          default:
            throw DBError.sqlRuntime("malformed JSON (escape)")
          }
          i += 1
          continue
        }
        out.append(b)
        i += 1
      }
      throw DBError.sqlRuntime("malformed JSON (unterminated string)")
    }

    mutating func unicodeEscape() throws(DBError) -> Unicode.Scalar? {
      func hex4() -> UInt32? {
        guard i + 5 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for k in 1...4 {
          let b = bytes[i + k]
          let digit: UInt32
          switch b {
          case 0x30...0x39: digit = UInt32(b - 0x30)
          case 0x41...0x46: digit = UInt32(b - 0x41 + 10)
          case 0x61...0x66: digit = UInt32(b - 0x61 + 10)
          default: return nil
          }
          v = v << 4 | digit
        }
        return v
      }
      guard let first = hex4() else { return nil }
      i += 5
      if first >= 0xD800, first <= 0xDBFF,
        i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 {
        i += 1 // backslash; hex4 expects i at 'u'
        if let second = hex4(), second >= 0xDC00, second <= 0xDFFF {
          i += 5
          let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
          return Unicode.Scalar(combined)
        }
        i -= 1
      }
      return Unicode.Scalar(first) ?? Unicode.Scalar(0xFFFD)
    }

    mutating func number() throws(DBError) -> Node {
      let start = i
      if i < bytes.count, bytes[i] == 0x2D { i += 1 }
      var isReal = false
      while i < bytes.count {
        let b = bytes[i]
        if b >= 0x30 && b <= 0x39 {
          i += 1
        } else if b == 0x2E || b == 0x65 || b == 0x45 || b == 0x2B || b == 0x2D {
          isReal = true
          i += 1
        } else {
          break
        }
      }
      guard i > start else { throw DBError.sqlRuntime("malformed JSON (number)") }
      let text = String(decoding: bytes[start..<i], as: UTF8.self)
      if !isReal, let v = Int64(text) { return .integer(v) }
      guard let d = Double(text) else { throw DBError.sqlRuntime("malformed JSON (number)") }
      return .real(d)
    }
  }

  // MARK: - SQL mappings

  /// SQLite json_extract value mapping.
  static func toSQL(_ node: Node) -> Value {
    switch node {
    case .null: return .null
    case .bool(let b): return .integer(b ? 1 : 0)
    case .integer(let v): return .integer(v)
    case .real(let d): return .real(d)
    case .string(let s): return .text(s)
    case .array, .object: return .text(render(node))
    }
  }

  static func render(_ node: Node) -> String {
    switch node {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .integer(let v): return String(v)
    case .real(let d): return SQLFunctions.realToText(d)
    case .string(let s): return renderString(s)
    case .array(let items):
      return "[" + items.map(render).joined(separator: ",") + "]"
    case .object(let members):
      return "{" + members.map { renderString($0.0) + ":" + render($0.1) }.joined(separator: ",") + "}"
    }
  }

  private static func renderString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += "\\u" + hex4(scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }

  /// json_extract(doc, '$.a.b[0]'): SQL NULL for missing paths or non-JSON.
  static func extract(_ json: String, path: String) throws(DBError) -> Value {
    guard let root = try? parse(json) else { return .null }
    var node = root
    var i = path.startIndex
    guard i < path.endIndex, path[i] == "$" else {
      throw DBError.sqlRuntime("json path must start with $")
    }
    i = path.index(after: i)
    while i < path.endIndex {
      if path[i] == "." {
        i = path.index(after: i)
        var key = ""
        while i < path.endIndex, path[i] != ".", path[i] != "[" {
          key.append(path[i])
          i = path.index(after: i)
        }
        guard case .object(let members) = node,
          let match = members.first(where: { $0.0 == key })
        else { return .null }
        node = match.1
      } else if path[i] == "[" {
        i = path.index(after: i)
        var digits = ""
        while i < path.endIndex, path[i] != "]" {
          digits.append(path[i])
          i = path.index(after: i)
        }
        guard i < path.endIndex else { throw DBError.sqlRuntime("json path missing ]") }
        i = path.index(after: i)
        guard case .array(let items) = node, let index = Int(digits), index >= 0,
          index < items.count
        else { return .null }
        node = items[index]
      } else {
        throw DBError.sqlRuntime("malformed json path")
      }
    }
    return toSQL(node)
  }

  /// json_each over an array (or single value): the `value` column rowset.
  static func eachValues(_ json: String) throws(DBError) -> [Value] {
    guard let root = try? parse(json) else {
      throw DBError.sqlRuntime("json_each: malformed JSON")
    }
    switch root {
    case .array(let items): return items.map(toSQL)
    case .object(let members): return members.map { toSQL($0.1) }
    default: return [toSQL(root)]
    }
  }
}

extension SQLJSON {
  static func hex4(_ value: UInt32) -> String {
    let hex = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
  }
}

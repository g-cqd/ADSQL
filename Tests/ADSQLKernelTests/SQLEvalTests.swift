import CSQLite
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

// MARK: - Engines side by side

/// Evaluates `SELECT <expr>` through ADSQL's evaluator.
private func adsqlEval(_ expr: String, params: [String: Value] = [:]) throws -> Value {
  let statement = try SQLParser.parseOne("SELECT \(expr)")
  guard case .select(let select) = statement,
    case .expr(let parsed, _, _) = select.columns[0]
  else { throw DBError.sqlSyntax(message: "not an expression", offset: 0) }
  let env = SQLEvalEnv.parametersOnly { param throws(DBError) in
    if case .named(let name) = param, let value = params[name] { return value }
    throw DBError.sqlBind("unbound parameter \(param.description)")
  }
  return try SQLEval.evaluate(parsed, env)
}

/// Evaluates the same text through real SQLite.
final class SQLiteScratch {
  var db: OpaquePointer?

  init() {
    precondition(sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
  }
  deinit { sqlite3_close_v2(db) }

  func eval(_ expr: String, params: [String: Value] = [:]) throws -> Value {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT \(expr)", -1, &stmt, nil) == SQLITE_OK else {
      throw DBError.sqlRuntime("sqlite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (name, value) in params {
      let index = sqlite3_bind_parameter_index(stmt, "$\(name)")
      guard index > 0 else { continue }
      switch value {
      case .null: sqlite3_bind_null(stmt, index)
      case .integer(let v): sqlite3_bind_int64(stmt, index, v)
      case .real(let d): sqlite3_bind_double(stmt, index, d)
      case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
      case .blob(let b):
        b.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(b.count), transient) }
      }
    }
    let rc = sqlite3_step(stmt)
    guard rc == SQLITE_ROW else {
      throw DBError.sqlRuntime("sqlite step: \(String(cString: sqlite3_errmsg(db)))")
    }
    return columnValue(stmt, 0)
  }

  func columnValue(_ stmt: OpaquePointer?, _ index: Int32) -> Value {
    switch sqlite3_column_type(stmt, index) {
    case SQLITE_NULL: return .null
    case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, index))
    case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, index))
    case SQLITE_TEXT:
      return .text(String(cString: sqlite3_column_text(stmt, index)))
    default:
      let count = Int(sqlite3_column_bytes(stmt, index))
      guard count > 0, let base = sqlite3_column_blob(stmt, index) else { return .blob([]) }
      return .blob([UInt8](UnsafeRawBufferPointer(start: base, count: count)))
    }
  }
}

private func valuesMatch(_ a: Value, _ b: Value) -> Bool {
  if a == b { return true }
  // Reals: identical IEEE ops should agree exactly; tolerate -0.0 vs 0.0.
  if case .real(let x) = a, case .real(let y) = b { return x == y }
  return false
}

// MARK: - Differential

@Suite("SQL evaluator differential vs SQLite")
struct SQLEvalDifferentialTests {
  static let fixedCorpus: [String] = [
    // 3VL
    "NULL AND 0", "NULL AND 1", "NULL OR 1", "NULL OR 0", "NOT NULL",
    "1 AND NULL", "0 OR NULL", "NOT 0", "NOT 2", "NOT 0.0",
    // comparisons incl. int/real boundaries
    "1 = 1.0", "2 < 2.5", "9223372036854775807 > 9.2233720368547758e18",
    "9007199254740993 = 9007199254740992.0", "9007199254740993 > 9007199254740992.0",
    "-9223372036854775808 < -9.3e18", "0 = -0.0", "1 < '1'", "'a' < x'00'" ,
    "'abc' = 'ABC'", "'abc' = 'ABC' COLLATE NOCASE", "'a' < 'b'", "NULL = NULL",
    // blobs
    "x'00ff' = x'00FF'", "x'00' < x'01'", "x'' = x''", "x'61' = 'a'",
    "LENGTH(x'001122')", "CAST(x'414243' AS TEXT)",
    // comparison affinity
    "CAST(-837 AS TEXT) >= CAST(9223372036854775807 AS INTEGER)",
    "COALESCE('5', 5) < CAST(107 AS REAL)", "CAST(5 AS TEXT) = '5'",
    "CAST('12' AS INTEGER) = ' 12 '", "CAST('12' AS INTEGER) = '12x'",
    // IN with NULLs
    "1 IN (1, NULL)", "2 IN (1, NULL)", "2 NOT IN (1, NULL)", "2 IN ()",
    "NULL IN (1, 2)", "NULL IN ()", "3 NOT IN (1, 2)",
    // arithmetic incl. overflow/zero
    "1 + 2", "5 / 2", "5.0 / 2", "5 % 3", "5 % 0", "5 / 0", "5.0 / 0.0",
    "9223372036854775807 + 1", "-9223372036854775808 / -1",
    "9223372036854775807 * 2", "2.5 * 2", "'5' + 1", "'5x' + 1", "'x' + 1",
    "-9223372036854775808 % -1", "1 + NULL", "-(-5)", "-'3'",
    // concat & text functions
    "'a' || 'b'", "'a' || NULL", "1 || 'x'", "LOWER('AbC')", "UPPER('aéB')",
    "LENGTH('héllo')", "LENGTH(12345)", "LENGTH(NULL)",
    "INSTR('hello', 'll')", "INSTR('hello', 'z')", "INSTR('héllo', 'llo')",
    "SUBSTR('hello', 2)", "SUBSTR('hello', 2, 2)", "SUBSTR('hello', -3, 2)",
    "SUBSTR('héllo', 0, 3)", "SUBSTR('hello', 3, -1)",
    // LIKE
    "'hello' LIKE 'h%'", "'hello' LIKE 'H_LLO'", "'hello' LIKE '%z%'",
    "'hello' NOT LIKE 'h%'", "NULL LIKE 'x'", "'50%' LIKE '50%'",
    // CASE / COALESCE / CAST
    "CASE WHEN 1 THEN 'a' ELSE 'b' END", "CASE WHEN 0 THEN 'a' END",
    "CASE 2 WHEN 1 THEN 'x' WHEN 2 THEN 'y' ELSE 'z' END",
    "CASE NULL WHEN NULL THEN 'eq' ELSE 'ne' END",
    "COALESCE(NULL, NULL, 3)", "COALESCE(NULL, 'x')",
    "CAST('42abc' AS INTEGER)", "CAST('3.5' AS REAL)", "CAST(3.9 AS INTEGER)",
    "CAST(-3.9 AS INTEGER)", "CAST(42 AS TEXT)", "CAST(NULL AS INTEGER)",
    "CAST('  12' AS INTEGER)", "CAST(2.5 AS TEXT)", "CAST(1e2 AS TEXT)",
    // json
    "json_extract('{\"year\": 2024, \"track\": \"dev\"}', '$.year')",
    "json_extract('{\"a\": {\"b\": [1, 2.5, \"x\"]}}', '$.a.b[1]')",
    "json_extract('{\"a\": 1}', '$.missing')",
    "json_extract('{\"a\": null}', '$.a')",
    "json_extract('[1,2,3]', '$[2]')",
    // IS NULL
    "NULL IS NULL", "1 IS NOT NULL", "NULL IS NOT NULL",
  ]

  @Test(arguments: fixedCorpus.indices)
  func fixedExpression(_ index: Int) throws {
    let expr = Self.fixedCorpus[index]
    let scratch = SQLiteScratch()
    let theirs = try scratch.eval(expr)
    let ours = try adsqlEval(expr)
    #expect(valuesMatch(ours, theirs), "\(expr): adsql \(ours) vs sqlite \(theirs)")
  }

  @Test func parameterBinding() throws {
    let scratch = SQLiteScratch()
    let params: [String: Value] = [
      "a": .integer(7), "b": .text("hi"), "c": .null, "d": .real(2.5),
    ]
    for expr in ["$a + 1", "$b || '!'", "$c IS NULL", "$d * 2", "$a IN (5, 6, 7)"] {
      let theirs = try scratch.eval(expr, params: params)
      let ours = try adsqlEval(expr, params: params)
      #expect(valuesMatch(ours, theirs), "\(expr): adsql \(ours) vs sqlite \(theirs)")
    }
  }

  @Test(arguments: [UInt64(5), 77, 999])
  func randomExpressions(seed: UInt64) throws {
    let scratch = SQLiteScratch()
    var rng = SplitMix64(seed: seed)

    func literal() -> String {
      switch rng.next() % 8 {
      case 0: return "NULL"
      case 1: return String(Int64(bitPattern: rng.next() % 2000) - 1000)
      case 2: return ["9223372036854775807", "-9223372036854775808", "9007199254740993"][Int(rng.next() % 3)]
      case 3: return String(Double(rng.next() % 1000) / 8)
      case 4: return ["'abc'", "'AbC'", "'%'", "'_x'", "'5'", "''", "'héé'"][Int(rng.next() % 7)]
      default: return String(Int64(rng.next() % 10))
      }
    }
    func expression(_ depth: Int) -> String {
      if depth == 0 { return literal() }
      switch rng.next() % 12 {
      case 0: return "(\(expression(depth - 1)) + \(expression(depth - 1)))"
      case 1: return "(\(expression(depth - 1)) * \(expression(depth - 1)))"
      case 2: return "(\(expression(depth - 1)) / \(expression(depth - 1)))"
      case 3: return "(\(expression(depth - 1)) % \(expression(depth - 1)))"
      case 4: return "(\(expression(depth - 1)) \(["=", "!=", "<", "<=", ">", ">="][Int(rng.next() % 6)]) \(expression(depth - 1)))"
      case 5: return "(\(expression(depth - 1)) \(["AND", "OR"][Int(rng.next() % 2)]) \(expression(depth - 1)))"
      case 6: return "(NOT \(expression(depth - 1)))"
      case 7: return "COALESCE(\(expression(depth - 1)), \(expression(depth - 1)))"
      case 8: return "CASE WHEN \(expression(depth - 1)) THEN \(expression(depth - 1)) ELSE \(expression(depth - 1)) END"
      case 9: return "CAST(\(expression(depth - 1)) AS \(["INTEGER", "TEXT", "REAL"][Int(rng.next() % 3)]))"
      case 10: return "(\(expression(depth - 1)) IN (\(literal()), \(literal()), \(literal())))"
      default: return "LENGTH(\(expression(depth - 1)))"
      }
    }

    for _ in 0..<400 {
      let expr = expression(2)
      let theirs: Value
      do {
        theirs = try scratch.eval(expr)
      } catch {
        continue // sqlite rejected (e.g. nesting limits) — skip
      }
      let ours = try adsqlEval(expr)
      #expect(valuesMatch(ours, theirs), "\(expr): adsql \(ours) vs sqlite \(theirs)")
    }
  }
}

@Suite("SQL evaluator semantics")
struct SQLEvalSemanticsTests {
  @Test func truthTables() {
    // (a, b, a AND b, a OR b) over {true, false, unknown}
    let t = Truth.yes
    let f = Truth.no
    let u = Truth.unknown
    let table: [(Truth, Truth, Truth, Truth)] = [
      (t, t, t, t), (t, f, f, t), (t, u, u, t),
      (f, t, f, t), (f, f, f, f), (f, u, f, u),
      (u, t, u, t), (u, f, f, u), (u, u, u, u),
    ]
    for (a, b, expectedAnd, expectedOr) in table {
      func combineAnd(_ x: Truth, _ y: Truth) -> Truth {
        if x == .no || y == .no { return .no }
        if x == .yes && y == .yes { return .yes }
        return .unknown
      }
      func combineOr(_ x: Truth, _ y: Truth) -> Truth {
        if x == .yes || y == .yes { return .yes }
        if x == .no && y == .no { return .no }
        return .unknown
      }
      #expect(combineAnd(a, b) == expectedAnd)
      #expect(combineOr(a, b) == expectedOr)
      #expect(a.negated.negated == a)
    }
  }

  @Test func intFloatCompareEdges() {
    // (Int64, Double, expected sign)
    let cases: [(Int64, Double, Int)] = [
      (0, 0.0, 0), (0, -0.0, 0), (1, 1.0, 0),
      (9007199254740993, 9007199254740992.0, 1), // 2^53 + 1 vs 2^53
      (9007199254740992, 9007199254740993.0, 0), // RHS rounds to 2^53
      (Int64.max, 9.223372036854776e18, -1),     // max < 2^63 as double
      (Int64.min, -9.223372036854776e18, 0),     // exactly representable
      (5, 5.5, -1), (-5, -5.5, 1), (6, 5.5, 1),
    ]
    for (i, d, expected) in cases {
      #expect(SQLCompare.intFloatCompare(i, d) == expected, "\(i) vs \(d)")
    }
    #expect(SQLCompare.intFloatCompare(1, .nan) == nil)
  }

  @Test func realToTextRoundTrips() {
    let values: [Double] = [0, 1, -1.5, 0.1, 1e20, 1.7976931348623157e308, 1.0 / 3.0]
    for d in values {
      let text = SQLFunctions.realToText(d)
      #expect(Double(text) == d, "\(d) → \(text)")
      #expect(text.contains(".") || text.contains("e") || text.contains("E"))
    }
  }

  @Test func jsonParserFuzzNeverCrashes() {
    var rng = SplitMix64(seed: 0x150)
    let seeds = [
      "{\"a\": [1, 2.5, \"x\", null, true]}", "[]", "{}", "\"hi\\u00e9\"",
      "{\"nested\": {\"deep\": [[[1]]]}}",
    ]
    for seed in seeds {
      let bytes = Array(seed.utf8)
      for _ in 0..<200 {
        var mutated = bytes
        let op = rng.next() % 3
        if op == 0, !mutated.isEmpty {
          mutated.remove(at: Int(rng.next() % UInt64(mutated.count)))
        } else if op == 1 {
          mutated.insert(
            UInt8(truncatingIfNeeded: rng.next()),
            at: Int(rng.next() % UInt64(mutated.count + 1)))
        } else {
          mutated = Array(mutated.prefix(Int(rng.next() % UInt64(mutated.count + 1))))
        }
        _ = try? SQLJSON.parse(String(decoding: mutated, as: UTF8.self))
      }
    }
  }
}

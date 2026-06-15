import Testing

@testable import ADSQLKernel

/// Unit coverage for the ADJSON-backed SQL JSON layer (parse → tape, SQLite-dialect
/// path walk, SQL value mapping, and the scalar functions). End-to-end use is exercised
/// through json_extract / json_each in the acceptance and compound suites; these pin the
/// tricky escape/path/number edges and the new function surface.
@Suite("SQLJSON")
struct SQLJSONTests {
    @Test func mapsScalarsWithSQLiteValueRules() throws {
        #expect(try SQLJSON.toSQL(SQLJSON.parse("null")) == .null)
        #expect(try SQLJSON.toSQL(SQLJSON.parse("true")) == .integer(1))
        #expect(try SQLJSON.toSQL(SQLJSON.parse("false")) == .integer(0))
        #expect(try SQLJSON.toSQL(SQLJSON.parse("42")) == .integer(42))
        #expect(try SQLJSON.toSQL(SQLJSON.parse("-3.5")) == .real(-3.5))
        #expect(try SQLJSON.toSQL(SQLJSON.parse("\"hi\"")) == .text("hi"))
    }

    @Test func decodesBasicStringEscapes() throws {
        // JSON `"a\n\t\"\\b\/"` → the bytes a, LF, TAB, ", \, b, /.
        #expect(try SQLJSON.toSQL(SQLJSON.parse("\"a\\n\\t\\\"\\\\b\\/\"")) == .text("a\n\t\"\\b/"))
    }

    @Test func decodesUnicodeAndSurrogatePairs() throws {
        #expect(try SQLJSON.toSQL(SQLJSON.parse("\"\\u00e9\"")) == .text("é"))  // BMP escape
        #expect(try SQLJSON.toSQL(SQLJSON.parse("\"\\uD83D\\uDE00\"")) == .text("😀"))  // surrogate pair
    }

    @Test func extractWalksObjectAndArrayPaths() throws {
        let doc = #"{"a":{"b":[10,20,30]},"c":"x"}"#
        #expect(try SQLJSON.extract(doc, path: "$.a.b[1]") == .integer(20))
        #expect(try SQLJSON.extract(doc, path: "$.c") == .text("x"))
        #expect(try SQLJSON.extract(doc, path: "$.a.b[9]") == .null)  // index out of range
        #expect(try SQLJSON.extract(doc, path: "$.missing") == .null)  // absent key
        #expect(try SQLJSON.extract(doc, path: "$.a.b[#-1]") == .integer(30))  // end-relative
        #expect(try SQLJSON.extract(doc, path: "$.a.b") == .text("[10,20,30]"))  // container → JSON text
    }

    @Test func extractHandlesMalformedInputs() throws {
        #expect(throws: DBError.self) { try SQLJSON.extract("{}", path: "a") }  // no leading $
        #expect(throws: DBError.self) { try SQLJSON.extract("[1]", path: "$[0") }  // missing ]
        // A non-JSON document is an error (SQLite rejects ill-formed JSON in json_extract).
        #expect(throws: DBError.self) { try SQLJSON.extract("not json", path: "$.a") }
    }

    @Test func parseRejectsTrailingAndUnterminated() throws {
        #expect(throws: DBError.self) { try SQLJSON.parse("1 2") }  // trailing content
        #expect(throws: DBError.self) { try SQLJSON.parse("\"abc") }  // unterminated string
        #expect(throws: DBError.self) { try SQLJSON.parse("{\"a\":}") }  // missing value
    }

    @Test func eachValuesOverArrayObjectScalar() throws {
        #expect(try SQLJSON.eachValues("[1,2,3]") == [.integer(1), .integer(2), .integer(3)])
        #expect(try SQLJSON.eachValues(#"{"x":1,"y":2}"#) == [.integer(1), .integer(2)])
        #expect(try SQLJSON.eachValues("7") == [.integer(7)])
    }

    @Test func renderIsCanonicalAndRoundTrips() throws {
        let text = #"{"k":[1,"v",true,null]}"#
        #expect(try SQLJSON.render(SQLJSON.parse(text)) == text)
    }

    // MARK: - Scalar functions

    @Test func typeNamesMatchSQLite() throws {
        let doc = #"{"a":[1,2.5,"s",true,null,{}]}"#
        #expect(try SQLJSON.type(doc, path: "$.a[0]") == .text("integer"))
        #expect(try SQLJSON.type(doc, path: "$.a[1]") == .text("real"))
        #expect(try SQLJSON.type(doc, path: "$.a[2]") == .text("text"))
        #expect(try SQLJSON.type(doc, path: "$.a[3]") == .text("true"))
        #expect(try SQLJSON.type(doc, path: "$.a[4]") == .text("null"))
        #expect(try SQLJSON.type(doc, path: "$.a[5]") == .text("object"))
        #expect(try SQLJSON.type(doc, path: "$.a") == .text("array"))
        #expect(try SQLJSON.type(doc, path: "$.missing") == .null)
    }

    @Test func arrayLengthCountsOrNull() throws {
        #expect(try SQLJSON.arrayLength("[1,2,3]", path: nil) == .integer(3))
        #expect(try SQLJSON.arrayLength(#"{"a":[1,2,3,4]}"#, path: "$.a") == .integer(4))
        #expect(try SQLJSON.arrayLength(#"{"a":1}"#, path: nil) == .integer(0))  // not an array
        #expect(try SQLJSON.arrayLength("[1,2,3]", path: "$.x") == .null)  // path doesn't resolve
    }

    @Test func validReportsWellformedness() {
        #expect(SQLJSON.valid(.text(#"{"a":1}"#)) == .integer(1))
        #expect(SQLJSON.valid(.text("{bad}")) == .integer(0))
        #expect(SQLJSON.valid(.null) == .null)
        #expect(SQLJSON.valid(.integer(42)) == .integer(1))
    }

    @Test func quoteRendersScalars() throws {
        #expect(try SQLJSON.quote(.null) == .text("null"))
        #expect(try SQLJSON.quote(.integer(42)) == .text("42"))
        #expect(try SQLJSON.quote(.text(#"a"b"#)) == .text(#""a\"b""#))
        #expect(throws: DBError.self) { try SQLJSON.quote(.blob([0x00])) }
    }

    @Test func extractMultiplePathsReturnsArray() throws {
        let doc = #"{"a":1,"b":"x","c":[2,3]}"#
        #expect(try SQLJSON.extractMultiple(doc, paths: ["$.a", "$.b"]) == .text(#"[1,"x"]"#))
        #expect(try SQLJSON.extractMultiple(doc, paths: ["$.a", "$.missing"]) == .text("[1,null]"))
        #expect(try SQLJSON.extractMultiple(doc, paths: ["$.c", "$.a"]) == .text("[[2,3],1]"))
    }

    // MARK: - Builders & mutations

    @Test func minifyValidatesAndCompacts() throws {
        #expect(try SQLJSON.minify(.text(#" { "a" : 1 , "b" : [ 2 , 3 ] } "#)) == .text(#"{"a":1,"b":[2,3]}"#))
        #expect(try SQLJSON.minify(.null) == .null)
        #expect(throws: DBError.self) { try SQLJSON.minify(.text("{bad}")) }
    }

    @Test func buildsArraysAndObjects() throws {
        #expect(try SQLJSON.array([.integer(1), .text("x"), .null, .real(2.5)]) == .text(#"[1,"x",null,2.5]"#))
        #expect(try SQLJSON.array([]) == .text("[]"))
        let pairs: [(key: Value, value: Value)] = [
            (key: .text("a"), value: .integer(1)), (key: .text("b"), value: .text("y")),
        ]
        #expect(try SQLJSON.object(pairs) == .text(#"{"a":1,"b":"y"}"#))
        #expect(throws: DBError.self) {
            try SQLJSON.object([(key: .integer(1), value: .integer(2))])  // label must be TEXT
        }
    }

    @Test func setInsertReplacePreserveIntRealAndSemantics() throws {
        // set creates or overwrites; an integer stays an integer (not 2.0)
        #expect(
            try SQLJSON.mutate(#"{"a":1}"#, [(path: "$.b", value: .integer(2))], mode: .set) == .text(#"{"a":1,"b":2}"#)
        )
        #expect(try SQLJSON.mutate(#"{"a":1}"#, [(path: "$.a", value: .real(2.5))], mode: .set) == .text(#"{"a":2.5}"#))
        // insert only fills an absent slot
        #expect(
            try SQLJSON.mutate(#"{"a":1}"#, [(path: "$.a", value: .integer(9))], mode: .insert) == .text(#"{"a":1}"#))
        #expect(
            try SQLJSON.mutate(#"{"a":1}"#, [(path: "$.b", value: .integer(9))], mode: .insert)
                == .text(#"{"a":1,"b":9}"#))
        // replace only overwrites a present slot
        #expect(
            try SQLJSON.mutate(#"{"a":1}"#, [(path: "$.b", value: .integer(9))], mode: .replace) == .text(#"{"a":1}"#))
        #expect(
            try SQLJSON.mutate(#"{"a":1}"#, [(path: "$.a", value: .integer(9))], mode: .replace) == .text(#"{"a":9}"#))
        // append [#] and end-relative [#-1] on arrays
        #expect(try SQLJSON.mutate("[1,2]", [(path: "$[#]", value: .integer(3))], mode: .set) == .text("[1,2,3]"))
        #expect(try SQLJSON.mutate("[1,2,3]", [(path: "$[#-1]", value: .integer(9))], mode: .set) == .text("[1,2,9]"))
        // set creates missing intermediate containers (object inferred from the next key)
        #expect(try SQLJSON.mutate("{}", [(path: "$.a.b", value: .integer(1))], mode: .set) == .text(#"{"a":{"b":1}}"#))
    }

    @Test func removeDeletesPathsOrRoot() throws {
        #expect(try SQLJSON.removePaths(#"{"a":1,"b":2}"#, paths: ["$.a"]) == .text(#"{"b":2}"#))
        #expect(try SQLJSON.removePaths("[10,20,30]", paths: ["$[1]"]) == .text("[10,30]"))
        #expect(try SQLJSON.removePaths(#"{"a":1}"#, paths: ["$"]) == .null)  // removing the root
        #expect(try SQLJSON.removePaths(#"{"a":1}"#, paths: ["$.missing"]) == .text(#"{"a":1}"#))  // no-op
    }

    @Test func patchMergesPerRFC7396() throws {
        #expect(try SQLJSON.patch(#"{"a":1,"b":2}"#, with: #"{"b":3,"c":4}"#) == .text(#"{"a":1,"b":3,"c":4}"#))
        #expect(try SQLJSON.patch(#"{"a":1,"b":2}"#, with: #"{"a":null}"#) == .text(#"{"b":2}"#))  // null deletes
        // deep merge of nested objects
        #expect(try SQLJSON.patch(#"{"a":{"x":1}}"#, with: #"{"a":{"y":2}}"#) == .text(#"{"a":{"x":1,"y":2}}"#))
        #expect(try SQLJSON.patch(#"{"a":1}"#, with: "42") == .text("42"))  // non-object patch replaces
    }

    @Test func arrowOperatorsSelectAndShape() throws {
        let doc = #"{"a":{"b":5},"c":"x"}"#
        // -> returns JSON (a string stays quoted); ->> returns the SQL scalar (unquoted)
        #expect(try SQLJSON.arrow(.text(doc), .text("$.c"), asJSON: true) == .text(#""x""#))
        #expect(try SQLJSON.arrow(.text(doc), .text("$.c"), asJSON: false) == .text("x"))
        #expect(try SQLJSON.arrow(.text(doc), .text("$.a"), asJSON: true) == .text(#"{"b":5}"#))
        // bare-label RHS → $."a"; integer RHS → $[n]
        #expect(try SQLJSON.arrow(.text(doc), .text("a"), asJSON: false) == .text(#"{"b":5}"#))
        #expect(try SQLJSON.arrow(.text("[1,2,3]"), .integer(2), asJSON: false) == .integer(3))
        // missing path and NULL operands → NULL
        #expect(try SQLJSON.arrow(.text(doc), .text("$.missing"), asJSON: true) == .null)
        #expect(try SQLJSON.arrow(.null, .text("$.a"), asJSON: false) == .null)
    }
}

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
}

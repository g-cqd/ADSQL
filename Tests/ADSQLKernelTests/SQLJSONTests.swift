import Testing

@testable import ADSQLKernel

/// Direct unit coverage for the no-Foundation JSON parser (health-check S3).
/// These units are otherwise only exercised end-to-end through json_extract /
/// json_each, leaving the tricky escape/surrogate and path edges untested.
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
        #expect(try SQLJSON.parse("\"a\\n\\t\\\"\\\\b\\/\"") == .string("a\n\t\"\\b/"))
    }

    @Test func decodesUnicodeAndSurrogatePairs() throws {
        // BMP escape.
        #expect(try SQLJSON.parse("\"\\u00e9\"") == .string("é"))
        // Astral-plane character via a surrogate pair → U+1F600 😀.
        #expect(try SQLJSON.parse("\"\\uD83D\\uDE00\"") == .string("😀"))
        // A lone high surrogate is not a valid scalar → U+FFFD replacement.
        #expect(try SQLJSON.parse("\"\\uD83D\"") == .string("\u{FFFD}"))
    }

    @Test func extractWalksObjectAndArrayPaths() throws {
        let doc = "{\"a\":{\"b\":[10,20,30]},\"c\":\"x\"}"
        #expect(try SQLJSON.extract(doc, path: "$.a.b[1]") == .integer(20))
        #expect(try SQLJSON.extract(doc, path: "$.c") == .text("x"))
        #expect(try SQLJSON.extract(doc, path: "$.a.b[9]") == .null)  // index out of range
        #expect(try SQLJSON.extract(doc, path: "$.missing") == .null)  // absent key
        // Container nodes map to their JSON text.
        #expect(try SQLJSON.extract(doc, path: "$.a.b") == .text("[10,20,30]"))
    }

    @Test func extractHandlesMalformedInputs() throws {
        #expect(throws: DBError.self) { try SQLJSON.extract("{}", path: "a") }  // no leading $
        #expect(throws: DBError.self) { try SQLJSON.extract("[1]", path: "$[0") }  // missing ]
        // A non-JSON document yields SQL NULL, not an error.
        #expect(try SQLJSON.extract("not json", path: "$.a") == .null)
    }

    @Test func parseRejectsTrailingAndUnterminated() throws {
        #expect(throws: DBError.self) { try SQLJSON.parse("1 2") }  // trailing content
        #expect(throws: DBError.self) { try SQLJSON.parse("\"abc") }  // unterminated string
        #expect(throws: DBError.self) { try SQLJSON.parse("{\"a\":}") }  // missing value
    }

    @Test func eachValuesOverArrayObjectScalar() throws {
        #expect(try SQLJSON.eachValues("[1,2,3]") == [.integer(1), .integer(2), .integer(3)])
        #expect(try SQLJSON.eachValues("{\"x\":1,\"y\":2}") == [.integer(1), .integer(2)])
        #expect(try SQLJSON.eachValues("7") == [.integer(7)])
    }

    @Test func renderIsCanonicalAndRoundTrips() throws {
        let node = try SQLJSON.parse("{\"k\":[1,\"v\",true,null]}")
        #expect(try SQLJSON.parse(SQLJSON.render(node)) == node)
    }
}

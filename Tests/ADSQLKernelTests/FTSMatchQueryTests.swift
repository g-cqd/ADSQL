import Testing
@testable import ADSQLKernel

@Suite("FTS5 — F3a MATCH query grammar")
struct FTSMatchQueryTests {
  private func parse(_ s: String) throws -> FTSQuery { try FTSQuery.parse(s) }
  private func phrase(_ t: String, _ prefix: Bool = false) -> FTSQuery {
    .phrase(text: t, prefix: prefix)
  }

  @Test func termsPhrasesAndPrefixes() throws {
    #expect(try parse("foo") == phrase("foo"))
    #expect(try parse("foo*") == phrase("foo", true))
    #expect(try parse("\"foo bar\"") == phrase("foo bar"))
    #expect(try parse("\"foo bar\"*") == phrase("foo bar", true))
  }

  @Test func booleanOperatorsAndImplicitAnd() throws {
    #expect(try parse("foo bar") == .and(phrase("foo"), phrase("bar")))  // implicit AND
    #expect(try parse("foo AND bar") == .and(phrase("foo"), phrase("bar")))
    #expect(try parse("foo OR bar") == .or(phrase("foo"), phrase("bar")))
    #expect(try parse("foo NOT bar") == .not(phrase("foo"), phrase("bar")))
  }

  @Test func precedenceColumnOverNotOverAndOverOr() throws {
    // AND binds tighter than OR.
    #expect(try parse("foo OR bar AND baz") == .or(phrase("foo"), .and(phrase("bar"), phrase("baz"))))
    // NOT binds tighter than AND.
    #expect(try parse("foo AND bar NOT baz") == .and(phrase("foo"), .not(phrase("bar"), phrase("baz"))))
    // Groups override.
    #expect(
      try parse("(foo OR bar) AND baz") == .and(.or(phrase("foo"), phrase("bar")), phrase("baz")))
  }

  @Test func columnFilters() throws {
    #expect(try parse("title : foo") == .column(columns: ["title"], phrase("foo")))
    #expect(try parse("title:foo") == .column(columns: ["title"], phrase("foo")))
    #expect(
      try parse("{title body} : foo") == .column(columns: ["title", "body"], phrase("foo")))
    // `:` is highest precedence → binds only the following primary.
    #expect(
      try parse("title:foo OR bar") == .or(.column(columns: ["title"], phrase("foo")), phrase("bar")))
  }

  @Test func appleDocsShapes() throws {
    // OR-of-trigrams (the trigram fuzzy tier).
    #expect(try parse("abc OR bcd OR cde") == .or(.or(phrase("abc"), phrase("bcd")), phrase("cde")))
    // prefix + group + boolean mix.
    let parsed = try parse("(swift* OR objc) NOT deprecated")
    #expect(parsed == .not(.or(phrase("swift", true), phrase("objc")), phrase("deprecated")))
  }

  @Test func rejectsMalformedQueries() {
    #expect(throws: DBError.self) { _ = try parse("") }
    #expect(throws: DBError.self) { _ = try parse("(foo OR bar") }  // unbalanced
    #expect(throws: DBError.self) { _ = try parse("foo AND") }  // dangling operator
    #expect(throws: DBError.self) { _ = try parse("{title body foo") }  // unterminated filter
  }
}

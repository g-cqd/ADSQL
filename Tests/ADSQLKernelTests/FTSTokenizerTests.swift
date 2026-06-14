import Testing

@testable import ADSQLKernel

private func terms(_ tokenizer: any FTSTokenizer, _ text: String) throws -> [String] {
    try tokenizer.allTokens(text).map { String(decoding: $0.term, as: UTF8.self) }
}

@Suite("FTS5 — F1 tokenizers")
struct FTSTokenizerTests {
    // MARK: unicode61

    @Test func unicode61SplitsAndFolds() throws {
        let tok = Unicode61Tokenizer()
        #expect(try terms(tok, "Hello, World! 123") == ["hello", "world", "123"])
        #expect(try terms(tok, "  spaced\tout\nlines ") == ["spaced", "out", "lines"])
        #expect(try terms(tok, "swift_case") == ["swift", "case"])  // '_' is a separator
    }

    @Test func unicode61PositionsAndSpans() throws {
        let tokens = try Unicode61Tokenizer().allTokens("foo bar")
        #expect(tokens.map(\.position) == [0, 1])
        #expect(tokens[0].start == 0 && tokens[0].end == 3)
        #expect(tokens[1].start == 4 && tokens[1].end == 7)
    }

    @Test func unicode61RemovesDiacriticsByDefault() throws {
        #expect(try terms(Unicode61Tokenizer(), "Café NAÏVE résumé") == ["cafe", "naive", "resume"])
        // remove_diacritics=0 keeps the accents (still case-folded).
        #expect(try terms(Unicode61Tokenizer(removeDiacritics: 0), "Café") == ["café"])
    }

    // MARK: porter (classic Porter, 1980 — matches SQLite fts5)

    @Test func porterStemVectors() {
        let vectors: [(String, String)] = [
            ("running", "run"), ("runs", "run"), ("happy", "happi"), ("sky", "sky"),
            ("cats", "cat"), ("caresses", "caress"), ("ponies", "poni"), ("caress", "caress"),
            ("ties", "ti"), ("feed", "feed"), ("agreed", "agre"), ("plastered", "plaster"),
            ("sing", "sing"), ("motoring", "motor"), ("meetings", "meet"),
        ]
        for (input, expected) in vectors {
            let stem = String(decoding: Porter.stem(Array(input.utf8)), as: UTF8.self)
            #expect(stem == expected, "porter(\(input)) = \(stem), expected \(expected)")
        }
    }

    @Test func porterTokenizerLowercasesAndStems() throws {
        let tok = PorterTokenizer(base: Unicode61Tokenizer())
        #expect(try terms(tok, "Running RUNS and cats") == ["run", "run", "and", "cat"])
    }

    @Test func porterLeavesNonASCIIIntact() {
        // A term that isn't pure ASCII a–z passes through the stemmer unchanged.
        let kept = String(decoding: Porter.stem(Array("café".utf8)), as: UTF8.self)
        #expect(kept == "café")
    }

    // MARK: trigram

    @Test func trigramSlidesAndFolds() throws {
        #expect(try terms(TrigramTokenizer(), "Hello") == ["hel", "ell", "llo"])
        #expect(try terms(TrigramTokenizer(caseSensitive: true), "Hello") == ["Hel", "ell", "llo"])
        #expect(try terms(TrigramTokenizer(), "ab").isEmpty)  // fewer than 3 characters
    }

    @Test func trigramPositionsAndSpans() throws {
        let tokens = try TrigramTokenizer().allTokens("abcd")
        #expect(tokens.map(\.position) == [0, 1])
        #expect(tokens[0].start == 0 && tokens[0].end == 3)
        #expect(tokens[1].start == 1 && tokens[1].end == 4)
    }

    // MARK: factory

    @Test func factoryBuildsFromSpecs() throws {
        #expect(try terms(FTSTokenizerFactory.make(["unicode61"]), "Foo Bar") == ["foo", "bar"])
        #expect(try terms(FTSTokenizerFactory.make(["porter", "unicode61"]), "running") == ["run"])
        #expect(
            try terms(FTSTokenizerFactory.make(["trigram", "case_sensitive", "0"]), "ABCD")
                == ["abc", "bcd"])
        #expect(throws: DBError.self) { _ = try FTSTokenizerFactory.make(["bogus"]) }
    }

    @Test func factoryBuildsTheAppleDocsSpecs() throws {
        // The four consumer tokenize specs must all construct.
        for spec in [["porter", "unicode61"], ["trigram", "case_sensitive", "0"]] {
            _ = try FTSTokenizerFactory.make(spec)
        }
    }
}

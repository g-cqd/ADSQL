import ADSQL
import ADSQLImport
import ADSQLSearch
import ADSQLTestSupport
import CSQLite
import Testing

/// M8 INT (RFC 0010 §2) — the `ad_storage_search_pages` framed-output proof.
///
/// This is the adoption-gate proof that ADSQL can serve apple-docs' frozen
/// `ad_storage_*` C ABI: it builds the SAME apple-docs-shaped corpus as
/// `AppleDocsMainQueryTests` (`AppleDocsFixture`), calls `ADSQLSearch`'s
/// `searchPagesFramed(_:_:)` (the Swift body of `ad_storage_search_pages`),
/// DECODES the §2.5 response bytes back into rows with an independent decoder that
/// walks the wire layout from the spec (not the encoder's types), and asserts
/// BYTE-PARITY against the SQLite oracle running the IDENTICAL §2.2 query
/// (`SearchQuery.sql`) with the IDENTICAL bindings (`SearchQuery.bindings`).
///
/// Parity is value + order exact, except the bm25 `rank` column (index 22),
/// compared within 1e-9 relative (FTS5's float arithmetic differs in the last
/// ULPs); `tier` (index 23) is exact. The framing header (`colCount`/`rowCount`)
/// is checked directly, including the zero-row case.
@Suite("apple-docs search-pages framing parity (RFC 0010 §2 INT)")
struct SearchPagesFramedTests {
    // MARK: - Probes

    /// A no-filter probe: only `query`/`raw`/`limit` set, the 13 filters all
    /// passthrough (the bare §2.2 hot path through the framed ABI).
    @Test func noFilterFramedMatchesSQLite() throws {
        try AppleDocsFixture.withImportedCorpus { db, src in
            for (query, raw) in AppleDocsFixture.probes {
                let params = SearchPagesParams(query: query, raw: raw, limit: 50)
                try expectFramedParity(db, src, params, label: "no-filter query='\(query)'")
            }
        }
    }

    /// The `sources_json` IN-list filter (`d.source_type IN (SELECT value FROM
    /// json_each($sources_json))`) through the framed path — the contracted
    /// `inJSONEach` shape, plus a passthrough nil.
    @Test func sourcesJSONInListFramed() throws {
        try AppleDocsFixture.withImportedCorpus { db, src in
            for (query, raw) in AppleDocsFixture.probes {
                for sources in [nil, "[\"doc\"]", "[\"doc\",\"wwdc\"]"] {
                    let params = SearchPagesParams(
                        query: query, raw: raw, limit: 50, sourcesJSON: sources)
                    try expectFramedParity(
                        db, src, params, label: "sources_json=\(sources ?? "nil") query='\(query)'")
                }
            }
        }
    }

    /// The `year` (`json_extract … AS INTEGER`) + `track_like` (`LIKE` over
    /// `json_extract … '$.track'`) JSON filters together through the framed path.
    @Test func yearAndTrackFramed() throws {
        try AppleDocsFixture.withImportedCorpus { db, src in
            for (query, raw) in AppleDocsFixture.probes {
                let bags: [(Int64?, String?)] = [
                    (nil, nil),
                    (2024, nil),
                    (nil, "%swiftui%"),
                    (2023, "graphics%"),
                ]
                for (year, track) in bags {
                    let params = SearchPagesParams(
                        query: query, raw: raw, limit: 50, year: year, trackLike: track)
                    try expectFramedParity(
                        db, src, params,
                        label: "year=\(year.map(String.init) ?? "nil") track=\(track ?? "nil") query='\(query)'")
                }
            }
        }
    }

    /// `deprecated_mode` lowering (`include`/`exclude`/`only` ⇒ the `$dep_exclude`
    /// / `$dep_only` guard pair) through the framed path — the default and both
    /// non-default modes.
    @Test func deprecatedModeFramed() throws {
        try AppleDocsFixture.withImportedCorpus { db, src in
            for (query, raw) in AppleDocsFixture.probes {
                for mode in ["include", "exclude", "only"] {
                    let params = SearchPagesParams(
                        query: query, raw: raw, limit: 50, deprecatedMode: mode)
                    try expectFramedParity(db, src, params, label: "deprecated=\(mode) query='\(query)'")
                }
            }
        }
    }

    /// A representative multi-filter bag (the closest shape to a live `/search`
    /// request): source_type + language='both' + deprecated exclude + a min-iOS
    /// platform range, all framed at once.
    @Test func representativeBagFramed() throws {
        try AppleDocsFixture.withImportedCorpus { db, src in
            for (query, raw) in AppleDocsFixture.probes {
                let params = SearchPagesParams(
                    query: query, raw: raw, limit: 50, sourceType: "doc", language: "both",
                    deprecatedMode: "exclude", minIOS: 26)
                try expectFramedParity(db, src, params, label: "representative query='\(query)'")
            }
        }
    }

    /// The NULL/empty-result case: a MATCH query that hits no rows must still frame
    /// a valid header — `[colCount=24][rowCount=0]` with no cells, decoding to zero
    /// rows — and that must equal the (empty) SQLite oracle result.
    @Test func emptyResultFraming() throws {
        try AppleDocsFixture.withImportedCorpus { db, src in
            // A token that appears in no seeded document.
            let params = SearchPagesParams(query: "zzzznonexistentterm", raw: "zzzznonexistentterm", limit: 50)
            let bytes = try searchPagesFramed(db, params)
            let frame = try decodeFrame(bytes)
            #expect(frame.columnCount == 24, "empty frame colCount \(frame.columnCount) != 24")
            #expect(frame.rowCount == 0, "empty frame rowCount \(frame.rowCount) != 0")
            #expect(frame.rows.isEmpty, "empty frame decoded \(frame.rows.count) rows")
            // The header is exactly 8 bytes (two u32) and nothing else for zero rows.
            #expect(bytes.count == 8, "empty frame is \(bytes.count) bytes, expected 8 (header only)")
            // Oracle agrees it is empty.
            let oracle = AppleDocsFixture.sqliteRows(src, SearchQuery.sql, SearchQuery.bindings(for: params))
            #expect(oracle.isEmpty, "oracle returned \(oracle.count) rows for the no-match probe")
        }
    }

    /// A `limit` smaller than the match count must frame exactly `limit` rows
    /// (proves the bound `$limit` flows through framing, and the rowCount header is
    /// the framed count, not the match count).
    @Test func limitBoundsFramedRowCount() throws {
        try AppleDocsFixture.withImportedCorpus { db, src in
            let params = SearchPagesParams(query: "view", raw: "View", limit: 3)
            let frame = try decodeFrame(try searchPagesFramed(db, params))
            #expect(frame.rowCount <= 3, "limit=3 framed \(frame.rowCount) rows")
            let oracle = AppleDocsFixture.sqliteRows(src, SearchQuery.sql, SearchQuery.bindings(for: params))
            #expect(
                frame.rowCount == oracle.count,
                "limit=3 framed \(frame.rowCount) rows vs oracle \(oracle.count)")
            try expectFramedParity(db, src, params, label: "limit=3 query='view'")
        }
    }

    // MARK: - The framed-vs-oracle diff

    /// Frames `params` via `searchPagesFramed`, decodes the §2.5 bytes, runs the
    /// SQLite oracle with the IDENTICAL `SearchQuery.sql` + `SearchQuery.bindings`,
    /// and asserts row-for-row, cell-for-cell parity (rank within 1e-9 relative,
    /// everything else exact). Also checks the framed `colCount`/`rowCount` header.
    private func expectFramedParity(
        _ db: Database, _ src: OpaquePointer?, _ params: SearchPagesParams, label: String
    ) throws {
        let frame = try decodeFrame(try searchPagesFramed(db, params))
        let oracle = AppleDocsFixture.sqliteRows(src, SearchQuery.sql, SearchQuery.bindings(for: params))

        #expect(frame.columnCount == 24, "\(label): framed colCount \(frame.columnCount) != 24")
        #expect(
            frame.rowCount == oracle.count,
            "\(label): framed rowCount \(frame.rowCount) vs oracle \(oracle.count)")
        #expect(
            frame.rows.count == oracle.count,
            "\(label): decoded \(frame.rows.count) rows vs oracle \(oracle.count)")

        for (rowIndex, (framedRow, oracleRow)) in zip(frame.rows, oracle).enumerated() {
            #expect(
                framedRow.count == oracleRow.count,
                "\(label): row \(rowIndex) width framed \(framedRow.count) vs oracle \(oracleRow.count)")
            for col in 0..<Swift.min(framedRow.count, oracleRow.count) {
                if col == Self.rankColumn {
                    let a = framedRow[col].doubleValue ?? .nan
                    let b = oracleRow[col].doubleValue ?? .nan
                    #expect(
                        abs(a - b) <= 1e-9 * Swift.max(abs(b), 1),
                        "\(label): row \(rowIndex) rank framed \(a) vs oracle \(b)")
                } else {
                    #expect(
                        framedRow[col] == oracleRow[col],
                        "\(label): row \(rowIndex) col \(col) framed \(framedRow[col]) vs oracle \(oracleRow[col])")
                }
            }
        }
    }

    private static let rankColumn = 22  // 0-based: the bm25 `rank` projection column
}

// MARK: - §2.5 decoder (independent of the encoder — walks the spec byte layout)

extension SearchPagesFramedTests {
    /// A decoded §2.5 frame: the header counts plus the materialized rows.
    struct DecodedFrame {
        let columnCount: Int
        let rowCount: Int
        let rows: [[Value]]
    }

    /// Decode error, so a malformed frame fails the test loudly rather than
    /// silently truncating.
    struct FrameError: Error, CustomStringConvertible {
        let description: String
    }

    /// Walks the RFC 0010 §2.5 response layout:
    ///   `[u32 colCount][u32 rowCount]` then `rowCount × colCount` cells, each
    ///   `[u8 tag][payload]` — `0`=NULL, `1`=INT `[i64 LE]`, `2`=REAL `[f64 LE]`,
    ///   `3`=TEXT `[u32 len][utf8]`, `4`=BLOB `[u32 len][bytes]`. All little-endian.
    /// This decoder re-derives the format from the spec (it does NOT use the
    /// encoder's internal `Tag`), so byte-parity here is a genuine cross-check.
    func decodeFrame(_ bytes: [UInt8]) throws -> DecodedFrame {
        var offset = 0

        func readU32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else {
                throw FrameError(description: "u32 underrun at offset \(offset) of \(bytes.count)")
            }
            // Little-endian reassembly (independent of host endianness).
            let value =
                UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            offset += 4
            return value
        }

        func readU64() throws -> UInt64 {
            guard offset + 8 <= bytes.count else {
                throw FrameError(description: "u64 underrun at offset \(offset) of \(bytes.count)")
            }
            var value: UInt64 = 0
            for i in 0..<8 {
                value |= UInt64(bytes[offset + i]) << (8 * i)
            }
            offset += 8
            return value
        }

        func readBytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else {
                throw FrameError(description: "byte underrun: need \(count) at \(offset) of \(bytes.count)")
            }
            let slice = Array(bytes[offset..<offset + count])
            offset += count
            return slice
        }

        func readCell() throws -> Value {
            guard offset < bytes.count else {
                throw FrameError(description: "tag underrun at offset \(offset)")
            }
            let tag = bytes[offset]
            offset += 1
            switch tag {
            case 0:
                return .null
            case 1:
                return .integer(Int64(bitPattern: try readU64()))
            case 2:
                return .real(Double(bitPattern: try readU64()))
            case 3:
                let length = Int(try readU32())
                let utf8 = try readBytes(length)
                // Foundation-free decode; the encoder wrote `Array(String.utf8)`, so
                // this round-trips exactly (no lossy substitution on valid input).
                return .text(String(decoding: utf8, as: UTF8.self))
            case 4:
                let length = Int(try readU32())
                return .blob(try readBytes(length))
            default:
                throw FrameError(description: "unknown cell tag \(tag) at offset \(offset - 1)")
            }
        }

        let columnCount = Int(try readU32())
        let rowCount = Int(try readU32())
        var rows: [[Value]] = []
        rows.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            var row: [Value] = []
            row.reserveCapacity(columnCount)
            for _ in 0..<columnCount {
                row.append(try readCell())
            }
            rows.append(row)
        }
        // The frame must be fully consumed — no trailing bytes.
        guard offset == bytes.count else {
            throw FrameError(
                description: "frame has \(bytes.count - offset) trailing bytes after \(rowCount) rows")
        }
        return DecodedFrame(columnCount: columnCount, rowCount: rowCount, rows: rows)
    }
}

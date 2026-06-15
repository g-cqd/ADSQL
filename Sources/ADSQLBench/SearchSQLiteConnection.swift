import ADSQL
import ADSQLSearch
import CSQLite

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A read-only SQLite connection that runs the apple-docs §2.2 query
/// (`SearchQuery.sql`) with `SearchQuery.bindings(for:)` and does
/// FRAMING-EQUIVALENT work: it steps every result row and reads each of the 24
/// projected columns into a byte buffer with the SAME §2.5 cell layout
/// `ResponseFraming` emits (`[u8 tag][payload]`). So the ADSQL-vs-SQLite compare
/// is end-to-end (query + materialize-to-bytes), not just `MATCH`.
///
/// `@unchecked Sendable`: each instance is a fresh connection confined to the
/// single bench thread that created it (the scaling sweep makes one per worker);
/// the `sqlite3*`/stmt handles are never touched from another thread — the same
/// contract `SQLiteReadConnection` (Drivers.swift) uses.
final class SearchSQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private var stmt: OpaquePointer?
    /// `$name` → 1-based bind index, resolved once at prepare (saves a
    /// `sqlite3_bind_parameter_index` string lookup per param per request).
    private let bindIndex: [String: Int32]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw SQLiteError.code(1, "search reader open failed")
        }
        // The apple-docs production read pragmas: WAL is set at build; readers ask
        // for NORMAL sync + a large mmap + per-connection page cache (the §1 setup).
        _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA mmap_size=10737418240", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA cache_size=-64000", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA busy_timeout=5000", nil, nil, nil)
        guard
            sqlite3_prepare_v3(
                db, SearchQuery.sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK
        else {
            throw SQLiteError.code(sqlite3_errcode(db), "search reader prepare")
        }
        var indices: [String: Int32] = [:]
        for name in SearchCorpus.paramNames {
            let index = sqlite3_bind_parameter_index(stmt, "$" + name)
            if index > 0 { indices[name] = index }
        }
        bindIndex = indices
    }

    deinit {
        sqlite3_finalize(stmt)
        sqlite3_close_v2(db)
    }

    /// Binds the §2.4 bag, steps all rows, and frames each cell into `[UInt8]`
    /// (the §2.5 layout) — returns the encoded byte count so the caller's
    /// `blackhole` keeps the work alive. This is the SQLite analog of ADSQL's
    /// `searchPagesFramed`.
    func frameBytes(_ params: SearchPagesParams) -> Int {
        bind(params)
        var out: [UInt8] = []
        out.reserveCapacity(8 + 64 * SearchQuery.columnCount * 9)
        // Header is written after the row loop (rowCount unknown up front); reserve 8.
        var rowCount: UInt32 = 0
        let columnCount = Int32(sqlite3_column_count(stmt))
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowCount += 1
            for col in 0..<columnCount { appendCell(&out, col) }
        }
        sqlite3_reset(stmt)
        // Prepend the §2.5 header `[u32 colCount][u32 rowCount]`.
        var header: [UInt8] = []
        appendU32(&header, UInt32(SearchQuery.columnCount))
        appendU32(&header, rowCount)
        return header.count + out.count
    }

    /// Just the row count (for the warm-up sanity check).
    func frameRowCount(_ params: SearchPagesParams) -> Int {
        bind(params)
        var rows = 0
        while sqlite3_step(stmt) == SQLITE_ROW { rows += 1 }
        sqlite3_reset(stmt)
        return rows
    }

    /// Raw `documents_fts MATCH` candidate count (pre-LIMIT, no JOIN/filters) for the
    /// FTS-import sanity table — the SQLite counterpart of
    /// `SearchPagesScenario.matchCountADSQL`. Prepared transiently (called only a
    /// handful of times at startup, never on the hot path).
    func matchCount(_ term: String) -> Int {
        var counter: OpaquePointer?
        defer { sqlite3_finalize(counter) }
        guard
            sqlite3_prepare_v2(
                db, "SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH ?1", -1, &counter,
                nil) == SQLITE_OK
        else { return 0 }
        sqlite3_bind_text(counter, 1, term, -1, SearchPagesScenario.transient)
        guard sqlite3_step(counter) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(counter, 0))
    }

    // MARK: - Binding

    private func bind(_ params: SearchPagesParams) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (name, value) in SearchQuery.bindings(for: params) {
            guard let index = bindIndex[name] else { continue }
            switch value {
            case .null: sqlite3_bind_null(stmt, index)
            case .integer(let v): sqlite3_bind_int64(stmt, index, v)
            case .real(let d): sqlite3_bind_double(stmt, index, d)
            case .text(let s):
                sqlite3_bind_text(stmt, index, s, -1, SearchPagesScenario.transient)
            case .blob(let bytes):
                _ = bytes.withUnsafeBytes {
                    sqlite3_bind_blob(
                        stmt, index, $0.baseAddress, Int32($0.count), SearchPagesScenario.transient)
                }
            }
        }
    }

    // MARK: - §2.5 cell encode (mirrors ResponseFraming's tags/layout)

    private func appendCell(_ out: inout [UInt8], _ col: Int32) {
        switch sqlite3_column_type(stmt, col) {
        case SQLITE_NULL:
            out.append(0)
        case SQLITE_INTEGER:
            out.append(1)
            appendU64(&out, UInt64(bitPattern: sqlite3_column_int64(stmt, col)))
        case SQLITE_FLOAT:
            out.append(2)
            appendU64(&out, sqlite3_column_double(stmt, col).bitPattern)
        case SQLITE_TEXT:
            out.append(3)
            let count = Int(sqlite3_column_bytes(stmt, col))
            appendU32(&out, UInt32(truncatingIfNeeded: count))
            if count > 0, let base = sqlite3_column_text(stmt, col) {
                out.append(contentsOf: UnsafeBufferPointer(start: base, count: count))
            }
        default:  // SQLITE_BLOB
            out.append(4)
            let count = Int(sqlite3_column_bytes(stmt, col))
            appendU32(&out, UInt32(truncatingIfNeeded: count))
            if count > 0, let base = sqlite3_column_blob(stmt, col) {
                out.append(
                    contentsOf: UnsafeRawBufferPointer(start: base, count: count).bindMemory(to: UInt8.self))
            }
        }
    }

    private func appendU32(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8(truncatingIfNeeded: value))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func appendU64(_ out: inout [UInt8], _ value: UInt64) {
        var shifted = value
        for _ in 0..<8 {
            out.append(UInt8(truncatingIfNeeded: shifted))
            shifted >>= 8
        }
    }
}

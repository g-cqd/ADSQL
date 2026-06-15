public import ADSQLKernel
import CSQLite

/// Read-only view of a source SQLite `.db` for the importer: schema introspection
/// (`sqlite_master` + `PRAGMA table_info`) and row iteration. The per-cell read
/// mirrors the dispatch the differential tests already use as their oracle.
public final class SQLiteSource {
    private let handle: OpaquePointer

    /// A source column resolved to a strict ADSQL type by SQLite affinity rules.
    public struct Column: Sendable {
        public let name: String
        public let type: ColumnType
        public let notNull: Bool
        /// True for the lone `INTEGER PRIMARY KEY` column (it aliases the rowid).
        public let isRowidAlias: Bool
    }

    public init(path: String) throws(DBError) {
        var opened: OpaquePointer?
        let rc = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(opened)
            throw DBError.io(errno: rc, op: "sqlite3_open_v2(\(path)): \(message)")
        }
        self.handle = opened
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: Introspection

    /// User table + virtual-table names (excludes `sqlite_*` internals), name-sorted.
    public func tableNames() throws(DBError) -> [String] {
        var names: [String] = []
        try query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ) { stmt in names.append(Self.text(stmt, 0)) }
        return names
    }

    /// The `CREATE …` text for a table (`sqlite_master.sql`); nil if absent.
    public func createSQL(of table: String) throws(DBError) -> String? {
        var sql: String?
        try query("SELECT sql FROM sqlite_master WHERE type='table' AND name = '\(escape(table))'") {
            stmt in
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL { sql = Self.text(stmt, 0) }
        }
        return sql
    }

    /// Columns of a table (in definition order), each mapped to a strict ADSQL
    /// `ColumnType` by SQLite affinity. The sole `INTEGER PRIMARY KEY` column, if
    /// any, is flagged as the rowid alias.
    public func columns(of table: String) throws(DBError) -> [Column] {
        var raw: [(name: String, type: ColumnType, notNull: Bool, pk: Int32)] = []
        try query("PRAGMA table_info(\"\(escapeIdent(table))\")") { stmt in
            raw.append(
                (
                    name: Self.text(stmt, 1),
                    type: Self.affinity(of: Self.text(stmt, 2)),
                    notNull: sqlite3_column_int(stmt, 3) != 0,
                    pk: sqlite3_column_int(stmt, 5)
                ))
        }
        let pkColumns = raw.filter { $0.pk != 0 }
        let aliasName: String? =
            (pkColumns.count == 1 && pkColumns[0].type == .integer) ? pkColumns[0].name : nil
        return raw.map {
            Column(name: $0.name, type: $0.type, notNull: $0.notNull, isRowidAlias: $0.name == aliasName)
        }
    }

    // MARK: Iteration

    /// Yields every row of `table` as `[Value]` in column order (matching `columns(of:)`).
    public func forEachRow(
        of table: String, columnCount: Int, _ body: ([Value]) throws(DBError) -> Void
    ) throws(DBError) {
        try query("SELECT * FROM \"\(escapeIdent(table))\"") { (stmt) throws(DBError) in
            var values: [Value] = []
            values.reserveCapacity(columnCount)
            for index in 0..<Int32(columnCount) { values.append(Self.cell(stmt, index)) }
            try body(values)
        }
    }

    /// Yields `(rowid, [text per source column])` for FTS reconstruction. `rowid`
    /// is SQLite's row identifier (equals the `INTEGER PRIMARY KEY` when aliased),
    /// so the FTS docid matches the documents-table join key. Non-text cells are
    /// rendered to text (SQLite indexes text).
    public func forEachFTSDoc(
        sourceTable: String, sourceColumns: [String],
        _ body: (Int64, [String]) throws(DBError) -> Void
    ) throws(DBError) {
        let projection = (["rowid"] + sourceColumns.map { "\"\(escapeIdent($0))\"" }).joined(
            separator: ", ")
        try query("SELECT \(projection) FROM \"\(escapeIdent(sourceTable))\"") { (stmt) throws(DBError) in
            let docid = sqlite3_column_int64(stmt, 0)
            var texts: [String] = []
            texts.reserveCapacity(sourceColumns.count)
            for index in 1...Int32(sourceColumns.count) {
                texts.append(Self.cell(stmt, index).coerced(to: .text).textValue ?? "")
            }
            try body(docid, texts)
        }
    }

    // MARK: Primitives

    private func query(
        _ sql: String, _ row: (OpaquePointer?) throws(DBError) -> Void
    ) throws(DBError) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.io(errno: 0, op: "sqlite3_prepare_v2: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: try row(stmt)
            case SQLITE_DONE: return
            default:
                throw DBError.io(errno: 0, op: "sqlite3_step: \(String(cString: sqlite3_errmsg(handle)))")
            }
        }
    }

    /// One cell → ADSQL `Value`, matching the test oracle's storage-class dispatch.
    private static func cell(_ stmt: OpaquePointer?, _ index: Int32) -> Value {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT: return .text(text(stmt, index))
        default:
            let count = Int(sqlite3_column_bytes(stmt, index))
            guard count > 0, let base = sqlite3_column_blob(stmt, index) else { return .blob([]) }
            return .blob([UInt8](UnsafeRawBufferPointer(start: base, count: count)))
        }
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    /// SQLite type-affinity (declared type → storage class), per the documented
    /// substring rules: INT → INTEGER; CHAR/CLOB/TEXT → TEXT; BLOB or empty → BLOB;
    /// REAL/FLOA/DOUB → REAL; otherwise (NUMERIC-ish) → TEXT (coercion-friendly).
    static func affinity(of declared: String) -> ColumnType {
        let upper = declared.uppercased()
        if upper.contains("INT") { return .integer }
        if upper.contains("CHAR") || upper.contains("CLOB") || upper.contains("TEXT") { return .text }
        if upper.isEmpty || upper.contains("BLOB") { return .blob }
        if upper.contains("REAL") || upper.contains("FLOA") || upper.contains("DOUB") { return .real }
        return .text
    }

    /// Doubles every `quote` character in `s` (SQL string/identifier escaping),
    /// Foundation-free.
    private func doubling(_ s: String, _ quote: Character) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for character in s {
            out.append(character)
            if character == quote { out.append(character) }
        }
        return out
    }
    private func escape(_ literal: String) -> String { doubling(literal, "'") }
    private func escapeIdent(_ ident: String) -> String { doubling(ident, "\"") }
}

extension Value {
    /// The text payload of a `.text` value (nil otherwise) — used after coercing a
    /// cell to `.text` for FTS indexing.
    fileprivate var textValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

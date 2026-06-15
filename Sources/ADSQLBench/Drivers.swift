import ADSQL
import CSQLite

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Common surface over both engines. Each engine uses its *intended*
/// concurrency model: ADSQL shares one handle across reader threads
/// (wait-free snapshot reads); SQLite opens one read-only connection per
/// reader thread (its supported pattern under WAL).
protocol KVDriver: AnyObject {
    static var engineName: String { get }
    init(path: String, durability: String) throws
    /// One transaction containing all pairs.
    func putBatch(_ pairs: [(key: [UInt8], value: [UInt8])]) throws
    func get(_ key: [UInt8]) throws -> Int?
    func makeReader() throws -> any KVReader
    func scanAll() throws -> (rows: Int, bytes: Int)
    func close()
}

/// Sendable because a reader is shared across the concurrent benchmark tasks
/// (ADSQL: one wait-free snapshot handle; SQLite: a per-task connection). The
/// conformance lets the bench hand a reader to a task without disabling the
/// concurrency check (Review 0001 F6).
protocol KVReader: AnyObject, Sendable {
    func get(_ key: [UInt8]) throws -> Int?
}

// MARK: - ADSQL

final class ADSQLDriver: KVDriver, KVReader, Sendable {
    static let engineName = "adsql"
    let db: Database

    init(path: String, durability: String) throws {
        let profile: DurabilityProfile =
            switch durability {
            case "full": .full
            case "none": .none
            default: .barrier
            }
        db = try Database.open(
            at: path, options: DatabaseOptions(durability: profile, maxMapSize: 32 << 30))
    }

    func putBatch(_ pairs: [(key: [UInt8], value: [UInt8])]) throws {
        try db.writeSync { (txn) throws(DBError) in
            for pair in pairs {
                try txn.put(pair.key, pair.value)
            }
        }
    }

    func get(_ key: [UInt8]) throws -> Int? {
        try db.read { (txn) throws(DBError) in
            try txn.withValue(forKey: key) { span in span?.byteCount }
        }
    }

    func makeReader() throws -> any KVReader { self }

    func scanAll() throws -> (rows: Int, bytes: Int) {
        try db.read { (txn) throws(DBError) in
            var rows = 0
            var bytes = 0
            try txn.withCursor { (cursor) throws(DBError) in
                guard try cursor.move(to: .first) else { return }
                repeat {
                    let length: Int? = try cursor.withCurrent { key, ref in key.count + ref.length }
                    rows += 1
                    bytes += length ?? 0
                } while try cursor.next()
            }
            return (rows, bytes)
        }
    }

    func close() { db.close() }
}

// MARK: - SQLite baseline

enum SQLiteError: Error {
    case code(Int32, String)
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDriver: KVDriver {
    static let engineName = "sqlite"
    let path: String
    let durability: String
    var db: OpaquePointer?
    var insertStmt: OpaquePointer?
    var selectStmt: OpaquePointer?

    init(path: String, durability: String) throws {
        self.path = path
        self.durability = durability
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw SQLiteError.code(1, "open failed")
        }
        db = handle
        // Mirrors apple-docs production pragmas; synchronous maps the requested
        // durability (FULL = fsync per WAL commit ≈ ADSQL .barrier semantics on
        // macOS; fullfsync mirrors .full; NORMAL/none relaxes).
        try exec("PRAGMA journal_mode=WAL")
        switch durability {
        case "full":
            try exec("PRAGMA synchronous=FULL")
            try exec("PRAGMA fullfsync=ON")
        case "none":
            try exec("PRAGMA synchronous=OFF")
        case "normal":
            try exec("PRAGMA synchronous=NORMAL")
        default:  // barrier analog
            try exec("PRAGMA synchronous=FULL")
        }
        try exec("PRAGMA cache_size=-64000")
        try exec("PRAGMA mmap_size=10737418240")
        try exec("PRAGMA busy_timeout=5000")
        try exec("CREATE TABLE IF NOT EXISTS kv (k BLOB PRIMARY KEY, v BLOB NOT NULL) WITHOUT ROWID")
        insertStmt = try prepare("INSERT OR REPLACE INTO kv (k, v) VALUES (?1, ?2)")
        selectStmt = try prepare("SELECT v FROM kv WHERE k = ?1")
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.code(sqlite3_errcode(db), sql)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK
        else {
            throw SQLiteError.code(sqlite3_errcode(db), sql)
        }
        return stmt
    }

    func putBatch(_ pairs: [(key: [UInt8], value: [UInt8])]) throws {
        try exec("BEGIN IMMEDIATE")
        for pair in pairs {
            sqlite3_reset(insertStmt)
            pair.key.withUnsafeBytes { k in
                _ = sqlite3_bind_blob(insertStmt, 1, k.baseAddress, Int32(k.count), transientDestructor)
            }
            pair.value.withUnsafeBytes { v in
                _ = sqlite3_bind_blob(insertStmt, 2, v.baseAddress, Int32(v.count), transientDestructor)
            }
            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                try exec("ROLLBACK")
                throw SQLiteError.code(sqlite3_errcode(db), "insert step")
            }
        }
        try exec("COMMIT")
    }

    func get(_ key: [UInt8]) throws -> Int? {
        Self.pointGet(selectStmt, key)
    }

    static func pointGet(_ stmt: OpaquePointer?, _ key: [UInt8]) -> Int? {
        sqlite3_reset(stmt)
        key.withUnsafeBytes { k in
            _ = sqlite3_bind_blob(stmt, 1, k.baseAddress, Int32(k.count), transientDestructor)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_bytes(stmt, 0))
    }

    func makeReader() throws -> any KVReader {
        try SQLiteReadConnection(path: path)
    }

    func scanAll() throws -> (rows: Int, bytes: Int) {
        let stmt = try prepare("SELECT k, v FROM kv ORDER BY k")
        defer { sqlite3_finalize(stmt) }
        var rows = 0
        var bytes = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows += 1
            bytes += Int(sqlite3_column_bytes(stmt, 0)) + Int(sqlite3_column_bytes(stmt, 1))
        }
        return (rows, bytes)
    }

    func close() {
        sqlite3_finalize(insertStmt)
        sqlite3_finalize(selectStmt)
        sqlite3_close_v2(db)
    }
}

/// @unchecked: each instance is a fresh read-only connection confined to the
/// single benchmark task it was created for; the `sqlite3*`/stmt handles are
/// never touched from another thread.
final class SQLiteReadConnection: KVReader, @unchecked Sendable {
    var db: OpaquePointer?
    var selectStmt: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw SQLiteError.code(1, "reader open failed")
        }
        _ = sqlite3_exec(db, "PRAGMA busy_timeout=5000", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA mmap_size=10737418240", nil, nil, nil)
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v3(
                db, "SELECT v FROM kv WHERE k = ?1", -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil)
                == SQLITE_OK
        else {
            throw SQLiteError.code(sqlite3_errcode(db), "reader prepare")
        }
        selectStmt = stmt
    }

    func get(_ key: [UInt8]) throws -> Int? {
        SQLiteDriver.pointGet(selectStmt, key)
    }

    deinit {
        sqlite3_finalize(selectStmt)
        sqlite3_close_v2(db)
    }
}

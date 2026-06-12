import Darwin

/// Complete error taxonomy for the kernel. Every fallible kernel API uses
/// `throws(DBError)` — there are no untyped throws below the façade.
public enum DBError: Error, Equatable, Sendable {
  case io(errno: Int32, op: String)
  case badMagic
  case unsupportedFormatVersion(UInt32)
  case unsupportedPageSize(UInt32)
  case corruptPage(pageNo: UInt64)
  case bothMetasInvalid
  case mapFull
  case readerSlotsExhausted
  case keyTooLarge(Int)
  case keyEmpty
  case txnClosed
  case databaseClosed
  case readOnlyDatabase
  case writerLockHeld(byPid: Int32)
  case snapshotDestinationExists
  case integrityFailure(String)

  // Relational layer
  case reservedKey
  case noSuchTable(String)
  case tableExists(String)
  case noSuchIndex(String)
  case indexExists(String)
  case noSuchColumn(table: String, column: String)
  case typeMismatch(table: String, column: String, expected: String, got: String)
  case notNullViolation(table: String, column: String)
  case uniqueViolation(table: String, index: String)
  case foreignKeyViolation(table: String)
  case indexKeyTooLarge(index: String, size: Int)
  case invalidDefinition(String)

  // SQL layer
  case sqlSyntax(message: String, offset: Int)
  case sqlUnsupported(String)
  case sqlBind(String)
  case sqlRuntime(String)
}

extension DBError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .io(let errno, let op):
      let detail = String(cString: strerror(errno))
      return "I/O error in \(op): \(detail) (errno \(errno))"
    case .badMagic: return "not an ADSQL database (bad magic)"
    case .unsupportedFormatVersion(let v): return "unsupported format version \(v)"
    case .unsupportedPageSize(let s): return "unsupported page size \(s)"
    case .corruptPage(let p): return "checksum mismatch on page \(p)"
    case .bothMetasInvalid: return "both meta pages invalid (empty or corrupt database)"
    case .mapFull: return "database exceeds maximum map size"
    case .readerSlotsExhausted: return "all reader slots in use"
    case .keyTooLarge(let n): return "key of \(n) bytes exceeds maximum \(Format.maxKeySize)"
    case .keyEmpty: return "empty keys are not permitted"
    case .txnClosed: return "transaction already ended"
    case .databaseClosed: return "database is closed"
    case .readOnlyDatabase: return "database opened read-only"
    case .writerLockHeld(let pid): return "another process (pid \(pid)) holds the writer lock"
    case .snapshotDestinationExists: return "snapshot destination already exists"
    case .integrityFailure(let why): return "integrity failure: \(why)"
    case .reservedKey: return "keys beginning with 0x00 are reserved for the catalog"
    case .noSuchTable(let name): return "no such table: \(name)"
    case .tableExists(let name): return "table already exists: \(name)"
    case .noSuchIndex(let name): return "no such index: \(name)"
    case .indexExists(let name): return "index already exists: \(name)"
    case .noSuchColumn(let table, let column): return "no such column: \(table).\(column)"
    case .typeMismatch(let table, let column, let expected, let got):
      return "type mismatch on \(table).\(column): expected \(expected), got \(got)"
    case .notNullViolation(let table, let column):
      return "NOT NULL violation: \(table).\(column)"
    case .uniqueViolation(let table, let index):
      return "UNIQUE violation on \(table) via index \(index)"
    case .foreignKeyViolation(let table): return "foreign key violation on \(table)"
    case .indexKeyTooLarge(let index, let size):
      return "encoded key for index \(index) is \(size) bytes (max \(Format.maxKeySize))"
    case .invalidDefinition(let why): return "invalid definition: \(why)"
    case .sqlSyntax(let message, let offset):
      return "SQL syntax error at offset \(offset): \(message)"
    case .sqlUnsupported(let construct):
      return "SQL construct not supported: \(construct)"
    case .sqlBind(let why): return "SQL bind error: \(why)"
    case .sqlRuntime(let why): return "SQL runtime error: \(why)"
    }
  }
}

@inline(__always)
func throwErrno(_ op: String) throws(DBError) -> Never {
  throw DBError.io(errno: errno, op: op)
}

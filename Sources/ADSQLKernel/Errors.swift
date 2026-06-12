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
    }
  }
}

@inline(__always)
func throwErrno(_ op: String) throws(DBError) -> Never {
  throw DBError.io(errno: errno, op: op)
}

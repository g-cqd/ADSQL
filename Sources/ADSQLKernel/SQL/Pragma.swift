/// PRAGMA compatibility shim. ADSQL governs durability and mapping through
/// `DatabaseOptions`, not through SQLite's journal/synchronous pragmas, so a
/// PRAGMA never errors: a setter is a no-op, a recognized getter returns one
/// plausible row, and an unrecognized pragma returns nothing (as SQLite does
/// for unknown pragmas). This lets a SQLite consumer's connection-setup script
/// run unchanged.
enum Pragma {
  static func run(name: String, value: String?) -> [SQLRow] {
    guard value == nil else { return [] }  // setter: accepted, no-op
    let header = SQLColumnHeader([name])
    func row(_ value: Value) -> [SQLRow] { [SQLRow(header: header, values: [value])] }
    switch name {
    case "journal_mode": return row(.text("wal"))
    case "synchronous": return row(.integer(2))
    case "foreign_keys": return row(.integer(1))  // ADSQL always enforces FKs
    case "page_size": return row(.integer(Int64(Format.pageSize)))
    case "mmap_size", "cache_size", "temp_store", "query_only", "user_version":
      return row(.integer(0))
    default:
      return []  // unknown pragma: silently empty
    }
  }
}

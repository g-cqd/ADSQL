import ADSQL
import Darwin

let usage = """
  adsql — ADSQL database tool

  usage:
    adsql create   <path>
    adsql put      <path> <key> <value>
    adsql get      <path> <key>
    adsql delete   <path> <key>
    adsql scan     <path> [limit]
    adsql stats    <path>
    adsql check    <path>
    adsql snapshot <path> <destination>
    adsql hold-read <path> <seconds>     # test helper: pin a read snapshot
  """

func fail(_ message: String) -> Never {
  FileHandle.standardError(message)
  exit(1)
}

enum FileHandle {
  static func standardError(_ message: String) {
    var text = message + "\n"
    text.withUTF8 { buf in
      _ = write(2, buf.baseAddress, buf.count)
    }
  }
}

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
func string(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
  print(usage)
  exit(arguments.count == 1 ? 0 : 1)
}
let command = arguments[1]
let path = arguments[2]

do {
  switch command {
  case "create":
    let db = try Database.open(at: path)
    print("created \(path) (generation \(db.generation))")
    db.close()

  case "put":
    guard arguments.count == 5 else { fail("usage: adsql put <path> <key> <value>") }
    let db = try Database.open(at: path)
    try db.writeSync { (txn) throws(DBError) in
      try txn.put(bytes(arguments[3]), bytes(arguments[4]))
    }
    db.close()

  case "get":
    guard arguments.count == 4 else { fail("usage: adsql get <path> <key>") }
    let db = try Database.open(at: path, options: DatabaseOptions(readOnly: true))
    let value = try db.read { (txn) throws(DBError) in try txn.get(bytes(arguments[3])) }
    db.close()
    guard let value else {
      FileHandle.standardError("(not found)")
      exit(2)
    }
    print(string(value))

  case "delete":
    guard arguments.count == 4 else { fail("usage: adsql delete <path> <key>") }
    let db = try Database.open(at: path)
    let existed = try db.writeSync { (txn) throws(DBError) in
      try txn.delete(bytes(arguments[3]))
    }
    db.close()
    if !existed {
      FileHandle.standardError("(not found)")
      exit(2)
    }

  case "scan":
    let limit = arguments.count >= 4 ? Int(arguments[3]) ?? Int.max : Int.max
    let db = try Database.open(at: path, options: DatabaseOptions(readOnly: true))
    let rows = try db.read { (txn) throws(DBError) in
      var rows: [(String, Int)] = []
      try txn.withCursor { (cursor) throws(DBError) in
        guard try cursor.move(to: .first) else { return }
        repeat {
          let row: (String, Int)? = try cursor.withCurrent { key, ref in
            (string([UInt8](key)), ref.length)
          }
          if let row { rows.append(row) }
          if rows.count >= limit { break }
        } while try cursor.next()
      }
      return rows
    }
    db.close()
    for (key, valueLength) in rows {
      print("\(key)\t\(valueLength)")
    }

  case "stats":
    let db = try Database.open(at: path, options: DatabaseOptions(readOnly: true))
    print("path:        \(db.path)")
    print("generation:  \(db.generation)")
    print("keys:        \(db.count)")
    db.close()

  case "check":
    let db = try Database.open(at: path, options: DatabaseOptions(readOnly: true))
    let report = try db.verifyIntegrity()
    db.close()
    print("ok — generation \(report.generation), \(report.kvCount) keys")
    print("pages: \(report.pageCount) total · \(report.mainTreePages) main · "
      + "\(report.overflowPages) overflow · \(report.freeTreePages) free-tree · "
      + "\(report.freeListedPages) free")
    print("depth: \(report.treeDepth)")

  case "snapshot":
    guard arguments.count == 4 else { fail("usage: adsql snapshot <path> <destination>") }
    let db = try Database.open(at: path)
    try db.snapshot(to: arguments[3])
    db.close()
    print("snapshot → \(arguments[3])")

  case "hold-read":
    guard arguments.count == 4, let seconds = Double(arguments[3]) else {
      fail("usage: adsql hold-read <path> <seconds>")
    }
    let db = try Database.open(at: path, options: DatabaseOptions(readOnly: true))
    try db.read { (txn) throws(DBError) in
      print("holding generation \(txn.generation) for \(seconds)s")
      usleep(UInt32(seconds * 1_000_000))
    }
    db.close()

  default:
    fail(usage)
  }
} catch {
  fail("error: \(error)")
}

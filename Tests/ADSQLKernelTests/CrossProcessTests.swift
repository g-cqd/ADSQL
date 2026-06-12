import Foundation
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

private final class BundleMarker {}

/// Locates the adsql CLI next to the test bundle in the build products dir.
private func adsqlBinary() -> String {
  Bundle(for: BundleMarker.self).bundleURL
    .deletingLastPathComponent()
    .appendingPathComponent("adsql")
    .path
}

@discardableResult
private func runCLI(_ arguments: [String]) throws -> (status: Int32, output: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: adsqlBinary())
  process.arguments = arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  process.waitUntilExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func launchCLI(_ arguments: [String]) throws -> Process {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: adsqlBinary())
  process.arguments = arguments
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()
  return process
}

@Suite("Cross-process", .serialized)
struct CrossProcessTests {
  @Test func cliBinaryExists() {
    #expect(FileManager.default.isExecutableFile(atPath: adsqlBinary()))
  }

  @Test func secondWriterProcessIsRejected() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = dir.file("excl.adsql")
    let db = try Database.open(at: path)
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in try txn.put([1], [1]) }

    // The child needs a read-write handle for `put` → must hit our fcntl lock.
    let result = try runCLI(["put", path, "key", "value"])
    #expect(result.status != 0)
    #expect(result.output.contains("writer lock"), "got: \(result.output)")

    // Read-only child commands are fine.
    let stats = try runCLI(["stats", path])
    #expect(stats.status == 0, "got: \(stats.output)")
  }

  @Test func childReaderIsVisibleAndPinsGeneration() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = dir.file("pin.adsql")
    let db = try Database.open(at: path)
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      for i in 0..<50 { try txn.put(Array("seed-\(i)".utf8), [UInt8](repeating: 1, count: 200)) }
    }
    let heldGeneration = db.generation

    let child = try launchCLI(["hold-read", path, "2.5"])
    defer { if child.isRunning { child.terminate() } }
    // Wait for the child to register its snapshot.
    var observed: UInt64?
    for _ in 0..<50 {
      usleep(50_000)
      if let minimum = db.readerTable.minimumGeneration() {
        observed = minimum
        break
      }
    }
    #expect(observed == heldGeneration, "child reader generation not visible")

    // Writer keeps committing while the child holds its snapshot; the
    // reclaim horizon must stay below the held generation.
    for i in 0..<10 {
      try db.writeSync { (txn) throws(DBError) in
        for k in 0..<50 {
          try txn.put(Array("seed-\(k)".utf8), [UInt8](repeating: UInt8(i), count: 200))
        }
      }
    }
    #expect(db.readerTable.minimumGeneration() == heldGeneration)

    child.waitUntilExit()
    #expect(child.terminationStatus == 0)
    // Slot cleared after the child exits cleanly.
    #expect(db.readerTable.minimumGeneration() == nil)

    let report = try db.verifyIntegrity()
    #expect(report.kvCount == 50)
  }

  @Test func killedReaderIsSweptAndReclamationResumes() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = dir.file("sweep.adsql")
    let db = try Database.open(at: path)
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in
      for i in 0..<50 { try txn.put(Array("sw-\(i)".utf8), [UInt8](repeating: 2, count: 300)) }
    }

    let child = try launchCLI(["hold-read", path, "30"])
    var registered = false
    for _ in 0..<50 {
      usleep(50_000)
      if db.readerTable.minimumGeneration() != nil {
        registered = true
        break
      }
    }
    #expect(registered, "child never registered")

    // SIGKILL: no cleanup runs in the child.
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()

    // The dead pid still occupies its slot until the writer sweeps it.
    try db.writeSync { (txn) throws(DBError) in try txn.put(Array("post".utf8), [3]) }
    #expect(db.readerTable.minimumGeneration() == nil, "stale slot survived the sweep")

    // Churn must reclaim again (file growth bounded) and stay sound.
    for i in 0..<20 {
      try db.writeSync { (txn) throws(DBError) in
        for k in 0..<50 {
          try txn.put(Array("sw-\(k)".utf8), [UInt8](repeating: UInt8(i), count: 300))
        }
      }
    }
    _ = try db.verifyIntegrity()
  }

  @Test func readOnlyProcessSeesFreshCommits() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let path = dir.file("fresh.adsql")
    let db = try Database.open(at: path)
    defer { db.close() }
    try db.writeSync { (txn) throws(DBError) in try txn.put(Array("k".utf8), Array("v1".utf8)) }

    // In-process read-only handle (its own recovery + per-read refresh).
    let ro = try Database.open(at: path, options: DatabaseOptions(readOnly: true))
    defer { ro.close() }
    let first = try ro.read { (txn) throws(DBError) in try txn.get(Array("k".utf8)) }
    #expect(first == Array("v1".utf8))

    try db.writeSync { (txn) throws(DBError) in try txn.put(Array("k".utf8), Array("v2".utf8)) }
    let second = try ro.read { (txn) throws(DBError) in try txn.get(Array("k".utf8)) }
    #expect(second == Array("v2".utf8), "read-only handle did not refresh meta")

    // Child process get sees the newest value too.
    let result = try runCLI(["get", path, "k"])
    #expect(result.status == 0)
    #expect(result.output.contains("v2"))
  }
}

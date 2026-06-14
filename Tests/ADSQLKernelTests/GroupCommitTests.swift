import Dispatch
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

@Suite("Group commit", .serialized)
struct GroupCommitTests {
  @Test func asyncWriteCommitsAndIsVisible() async throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("gc.adsql"))
    defer { db.close() }

    let returned = try await db.write { (txn) throws(DBError) in
      try txn.put(Array("async".utf8), Array("yes".utf8))
      return 42
    }
    #expect(returned == 42)
    let value = try db.read { (txn) throws(DBError) in try txn.get(Array("async".utf8)) }
    #expect(value == Array("yes".utf8))
    #expect(db.generation == 1)
  }

  @Test func concurrentWritesBatchIntoFewCommits() async throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("batch.adsql"))
    defer { db.close() }

    // Occupy the writer queue so queued writes pile into batches. The
    // writer queue is serial: every batch drains strictly after this
    // blocker transaction returns, so no extra join is needed.
    let blocker = DispatchSemaphore(value: 0)
    let blockerTask = Task.detached {
      try? db.writeSync { (txn) throws(DBError) in
        try txn.put(Array("blocker".utf8), [1])
        blocker.wait()
      }
    }

    let writes = 100
    let results = try await withThrowingTaskGroup(of: Int.self) { tasks in
      for i in 0..<writes {
        tasks.addTask {
          try await db.write { (txn) throws(DBError) in
            try txn.put(Array("gc-\(i)".utf8), Array("v\(i)".utf8))
            return i
          }
        }
      }
      // Everything is enqueued behind the blocker; release it.
      blocker.signal()
      var collected: Set<Int> = []
      for try await i in tasks { collected.insert(i) }
      return collected
    }
    _ = await blockerTask.value

    #expect(results.count == writes)
    // Group commit: 100 writes must NOT cost 100 generations.
    #expect(db.generation < 20, "generation \(db.generation) — batching is not happening")
    #expect(db.count == UInt64(writes) + 1)

    let scanned = try db.read { (txn) throws(DBError) in
      var found = 0
      try txn.forEach { _, _ in found += 1 }
      return found
    }
    #expect(scanned == writes + 1)
  }

  @Test func failedRequestRollsBackOnlyItsDelta() async throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("isolate.adsql"))
    defer { db.close() }

    // Stall the queue so all three requests land in one batch.
    let blocker = DispatchSemaphore(value: 0)
    let blockerTask = Task.detached {
      try? db.writeSync { (txn) throws(DBError) in
        try txn.put(Array("warm".utf8), [0])
        blocker.wait()
      }
    }

    async let first: Void = db.write { (txn) throws(DBError) in
      try txn.put(Array("good-1".utf8), [1])
    }
    async let poisoned: Void = db.write { (txn) throws(DBError) in
      try txn.put(Array("ghost".utf8), [66])
      try txn.put([], [0]) // throws keyEmpty → this request rolls back
    }
    async let second: Void = db.write { (txn) throws(DBError) in
      try txn.put(Array("good-2".utf8), [2])
    }
    blocker.signal()

    try await first
    do {
      try await poisoned
      Issue.record("poisoned write must throw")
    } catch {
      #expect(error as? DBError == DBError.keyEmpty)
    }
    try await second
    _ = await blockerTask.value

    let state = try db.read { (txn) throws(DBError) in
      (good1: try txn.get(Array("good-1".utf8)),
       good2: try txn.get(Array("good-2".utf8)),
       ghost: try txn.get(Array("ghost".utf8)))
    }
    #expect(state.good1 == [1])
    #expect(state.good2 == [2])
    #expect(state.ghost == nil, "rolled-back request leaked data")

    // Structure + liveness must survive mid-batch rollbacks.
    db.close()
    let channel = try FileChannel(path: dir.file("isolate.adsql"), mode: .readOnly)
    defer { channel.close() }
    let meta = try Recovery.openOrCreate(channel: channel, createIfMissing: false)
    let pager = try Pager(channel: channel, maxMapSize: 1 << 28)
    _ = try KernelOps.checkLiveness(CommittedResolver(source: pager), meta)
  }

  /// F6f: one request buffers FTS docs; a SECOND request in the same batch forces
  /// a flush of the shared buffer (via a MATCH) and then fails. The failing
  /// request's rollback must undo its flush yet leave the first request's docs to
  /// be re-flushed at commit — the most intricate memtable/group-commit
  /// interaction (the buffer lives in value-typed RelationState; the flush's pages
  /// are request-epoch-undoable).
  @Test func ftsBufferSurvivesAnotherRequestsRollback() async throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("ftsgc.adsql"))
    defer { db.close() }
    try db.prepare("CREATE VIRTUAL TABLE fts USING fts5(body, tokenize='porter unicode61')").run()

    // Stall the queue so both async writes land in one batch.
    let blocker = DispatchSemaphore(value: 0)
    let blockerTask = Task.detached {
      try? db.writeSync { (txn) throws(DBError) in
        try txn.put(Array("warm".utf8), [0])
        blocker.wait()
      }
    }
    // A: buffers FTS docs (no tree write yet).
    async let good: Void = db.write { (txn) throws(DBError) in
      try txn.ftsAdd("fts", docid: 1, columnTexts: ["alpha"])
      try txn.ftsAdd("fts", docid: 2, columnTexts: ["beta"])
    }
    // B (same batch): adds its own doc, forces a flush of the shared buffer via a
    // MATCH (writing 1,2,3 under B's request epoch), then throws — rolling back
    // ONLY its own doc.
    async let poisoned: Void = db.write { (txn) throws(DBError) in
      try txn.ftsAdd("fts", docid: 3, columnTexts: ["gamma"])
      _ = try txn.ftsMatch("fts", "alpha")
      try txn.put([], [0])  // keyEmpty → this request rolls back
    }
    blocker.signal()
    try await good
    do {
      try await poisoned
      Issue.record("poisoned write must throw")
    } catch {
      #expect(error as? DBError == DBError.keyEmpty)
    }
    _ = await blockerTask.value

    func match(_ query: String) throws -> [Int64] {
      try db.prepare("SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY rowid").all(.text(query))
        .map { row in
          guard case .integer(let id) = row[0] else { return Int64(-1) }
          return id
        }
    }
    #expect(try match("alpha") == [1])
    #expect(try match("beta") == [2])
    #expect(try match("gamma") == [], "rolled-back request leaked an FTS doc")
  }

  @Test func closedDatabaseFailsQueuedWrites() async throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("late.adsql"))
    db.close()
    do {
      try await db.write { (txn) throws(DBError) in try txn.put([1], [1]) }
      Issue.record("write after close must throw")
    } catch {
      #expect(error == DBError.databaseClosed)
    }
  }

  @Test func mixedSyncAndAsyncWritersStaySerialized() async throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let db = try Database.open(at: dir.file("mixed.adsql"))
    defer { db.close() }

    try await withThrowingTaskGroup(of: Void.self) { tasks in
      for i in 0..<20 {
        tasks.addTask {
          try await db.write { (txn) throws(DBError) in
            try txn.put(Array("async-\(i)".utf8), [UInt8(i)])
          }
        }
        tasks.addTask {
          try db.writeSync { (txn) throws(DBError) in
            try txn.put(Array("sync-\(i)".utf8), [UInt8(i)])
          }
        }
      }
      try await tasks.waitForAll()
    }
    #expect(db.count == 40)
    let resolver = CommittedResolver(source: db.pager)
    let meta = db.shared.withLock { $0.meta }
    _ = try KernelOps.checkLiveness(resolver, meta)
  }
}

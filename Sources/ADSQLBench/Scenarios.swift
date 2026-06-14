import ADSQL
import Darwin
import Dispatch
import Foundation
import Synchronization

struct BenchConfig {
  var rows = 200_000
  var batchSize = 64
  var readerCounts = [1, 4, 8, 12, 16]
  var concurrentSeconds = 2.0
  var pointGets = 30_000
  var coldIterations = 40
  /// Per-row evaluator strategy for the SQL scenarios (`--eval`).
  var evaluator: ExecutionOptions.Evaluator = .treeWalk
  /// Join strategy for the SQL scenarios (`--join`).
  var joinStrategy: ExecutionOptions.Join = .nestedLoop
  /// Insert strategy for the SQL scenarios (`--insert`).
  var insertStrategy: ExecutionOptions.Insert = .standard
}

enum Scenarios {
  static func makeDriver(_ engine: String, path: String, durability: String) throws -> any KVDriver {
    engine == "adsql"
      ? try ADSQLDriver(path: path, durability: durability)
      : try SQLiteDriver(path: path, durability: durability)
  }

  static func datasetPath(_ dir: String, _ engine: String) -> String {
    "\(dir)/bench-\(engine).db"
  }

  /// Loads the document_chunks-shaped dataset once per engine.
  static func loadDataset(
    _ engine: String, dir: String, config: BenchConfig
  ) throws -> String {
    let path = datasetPath(dir, engine)
    unlink(path)
    unlink(path + "-wal")
    unlink(path + "-shm")
    unlink(path + "-lock")
    let driver = try makeDriver(engine, path: path, durability: "none")
    var rng = BenchRNG(seed: 7)
    var batch: [(key: [UInt8], value: [UInt8])] = []
    let start = nowNanos()
    for i in 0..<config.rows {
      batch.append((key: Workload.key(i), value: Workload.value(i, rng: &rng)))
      if batch.count == 512 {
        try driver.putBatch(batch)
        batch.removeAll(keepingCapacity: true)
      }
    }
    if !batch.isEmpty { try driver.putBatch(batch) }
    let elapsed = nowNanos() - start
    driver.close()
    print("  [\(engine)] dataset: \(config.rows) rows in \(elapsed / 1_000_000) ms (\(formatRate(config.rows, elapsed)))")
    return path
  }

  // MARK: 1. Cold open → first get

  static func coldOpen(_ engine: String, path: String, config: BenchConfig) throws {
    var histogram = LatencyHistogram()
    let probe = Workload.key(config.rows / 2)
    for _ in 0..<config.coldIterations {
      let start = nowNanos()
      let driver = try makeDriver(engine, path: path, durability: "none")
      _ = try driver.get(probe)
      histogram.record(nowNanos() - start)
      driver.close()
    }
    print("  [\(engine)] cold open→get   \(histogram.summary())")
  }

  // MARK: 2. Point gets (uniform + skewed)

  static func pointGets(_ engine: String, path: String, config: BenchConfig) throws {
    let driver = try makeDriver(engine, path: path, durability: "none")
    defer { driver.close() }
    for (label, skewed) in [("uniform", false), ("skewed ", true)] {
      var rng = BenchRNG(seed: 99)
      var histogram = LatencyHistogram()
      histogram.reserve(config.pointGets)
      var misses = 0
      for _ in 0..<config.pointGets {
        let index = skewed
          ? Workload.skewedIndex(&rng, rows: config.rows)
          : Int(rng.next() % UInt64(config.rows))
        let key = Workload.key(index)
        let start = nowNanos()
        if try driver.get(key) == nil { misses += 1 }
        histogram.record(nowNanos() - start)
      }
      precondition(misses == 0, "bench keys must all exist")
      print("  [\(engine)] get \(label)    \(histogram.summary())")
    }
  }

  // MARK: 3. Full scan

  static func scan(_ engine: String, path: String, config: BenchConfig) throws {
    let driver = try makeDriver(engine, path: path, durability: "none")
    defer { driver.close() }
    let start = nowNanos()
    let result = try driver.scanAll()
    let elapsed = nowNanos() - start
    let mbps = Double(result.bytes) / 1e6 / (Double(elapsed) / 1e9)
    precondition(result.rows == config.rows)
    print(String(
      format: "  [%@] scan            %d rows, %.0f MB/s (%llu ms)",
      engine, result.rows, mbps, elapsed / 1_000_000))
  }

  // MARK: 4. Concurrent readers during write churn (headline)

  static func concurrent(_ engine: String, path: String, config: BenchConfig) throws {
    for readers in config.readerCounts {
      let driver = try makeDriver(engine, path: path, durability: "none")
      let stop = Atomic<Bool>(false)
      let group = DispatchGroup()
      let collected = Mutex<[LatencyHistogram]>([])

      for _ in 0..<readers {
        let reader = try driver.makeReader()  // any KVReader: Sendable
        DispatchQueue.global().async(group: group) {
          var rng = BenchRNG(seed: nowNanos())
          var histogram = LatencyHistogram()
          histogram.reserve(200_000)
          while !stop.load(ordering: .relaxed) {
            let key = Workload.key(Int(rng.next() % UInt64(config.rows)))
            let start = nowNanos()
            _ = try? reader.get(key)
            histogram.record(nowNanos() - start)
          }
          collected.withLock { $0.append(histogram) }
        }
      }

      // Writer churn: continuous 64-row batches over a rolling window.
      var writerRows = 0
      var writerError: (any Error)?
      let writerStart = nowNanos()
      var rng = BenchRNG(seed: 1234)
      let deadline = writerStart + UInt64(config.concurrentSeconds * 1e9)
      while nowNanos() < deadline {
        var batch: [(key: [UInt8], value: [UInt8])] = []
        for _ in 0..<config.batchSize {
          let index = Int(rng.next() % UInt64(config.rows))
          batch.append((key: Workload.key(index), value: Workload.value(index, rng: &rng)))
        }
        do {
          try driver.putBatch(batch)
          writerRows += config.batchSize
        } catch {
          writerError = error
          break
        }
      }
      let writerElapsed = nowNanos() - writerStart
      stop.store(true, ordering: .relaxed)
      group.wait()
      driver.close()
      if let writerError { throw writerError }

      var merged = LatencyHistogram()
      var totalReads = 0
      collected.withLock { histograms in
        for histogram in histograms {
          totalReads += histogram.count
          merged.samples.append(contentsOf: histogram.samples)
        }
      }
      print(String(
        format: "  [%@] %2d readers   reads %@  %@   writer %@ rows/s",
        engine, readers, formatRate(totalReads, writerElapsed), merged.summary(),
        formatRate(writerRows, writerElapsed)))
    }
  }

  // MARK: 5. Batch upserts per durability profile

  static func upserts(_ engine: String, dir: String, config: BenchConfig) throws {
    let durabilities = engine == "sqlite" ? ["none", "normal", "barrier", "full"] : ["none", "barrier", "full"]
    for durability in durabilities {
      let path = "\(dir)/upsert-\(engine)-\(durability).db"
      unlink(path)
      unlink(path + "-wal")
      unlink(path + "-shm")
      let driver = try makeDriver(engine, path: path, durability: durability)
      var rng = BenchRNG(seed: 5)
      let batches = durability == "full" ? 60 : 400
      var commit = LatencyHistogram()
      let start = nowNanos()
      var index = 0
      for _ in 0..<batches {
        var batch: [(key: [UInt8], value: [UInt8])] = []
        for _ in 0..<config.batchSize {
          batch.append((key: Workload.key(index), value: Workload.value(index, rng: &rng)))
          index += 1
        }
        let batchStart = nowNanos()
        try driver.putBatch(batch)
        commit.record(nowNanos() - batchStart)
      }
      let elapsed = nowNanos() - start
      driver.close()
      print(String(
        format: "  [%@] upsert %-8@ %@ rows/s   commit %@",
        engine, durability, formatRate(batches * config.batchSize, elapsed), commit.summary()))
    }
  }
}

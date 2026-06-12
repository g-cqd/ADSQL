import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

/// Applies a put through the public BTree entry point.
private func put(_ ctx: TxnContext, _ key: [UInt8], _ value: [UInt8]) throws {
  var failure: DBError?
  key.withUnsafeBytes { k in
    value.withUnsafeBytes { v in
      do throws(DBError) {
        try BTree.put(ctx: ctx, key: k, value: v)
      } catch {
        failure = error
      }
    }
  }
  if let failure { throw failure }
}

private func get(_ resolver: some PageResolver, _ meta: Meta, _ key: [UInt8]) throws -> [UInt8]? {
  var result: Result<[UInt8]?, DBError> = .success(nil)
  key.withUnsafeBytes { k in
    do throws(DBError) {
      guard let ref = try BTree.get(resolver: resolver, meta: meta, key: k) else {
        result = .success(nil)
        return
      }
      result = .success(try BTree.copyValue(ref, resolver: resolver))
    } catch {
      result = .failure(error)
    }
  }
  return try result.get()
}

/// Full scan via forEach, materializing values.
private func scanAll(_ resolver: some PageResolver, _ meta: Meta) throws -> [(key: [UInt8], value: [UInt8])] {
  var out: [(key: [UInt8], value: [UInt8])] = []
  try BTree.forEach(resolver: resolver, meta: meta) { (key, ref) throws(DBError) in
    out.append((key: [UInt8](key), value: try BTree.copyValue(ref, resolver: resolver)))
  }
  return out
}

@Suite("BTree model tests")
struct BTreeModelTests {
  @Test(arguments: [UInt64(1), 7, 42, 1234, 0xDEAD])
  func randomPutsMatchModel(seed: UInt64) throws {
    let kernel = MemKernel()
    var model = ModelStore()
    let ops = OpScript.generate(seed: seed, count: 4000, keySpace: 1500)

    var ctx = kernel.begin()
    for (i, op) in ops.enumerated() {
      guard case .put(let key, let value) = op else { continue }
      try put(ctx, key, value)
      model.put(key, value)

      if i % 257 == 0 {
        kernel.commit(ctx)
        ctx = kernel.begin()
      }
    }
    kernel.commit(ctx)

    // Structure is sound.
    let report = try BTree.validate(resolver: CommittedResolver(source: kernel), meta: kernel.meta)
    #expect(report.kvCount == UInt64(model.count))
    #expect(report.leafCount > 1)

    // Contents match the model exactly, in order.
    let resolver = CommittedResolver(source: kernel)
    let scanned = try scanAll(resolver, kernel.meta)
    let expected = model.sortedPairs()
    #expect(scanned.count == expected.count)
    for (got, want) in zip(scanned, expected) {
      #expect(got.key == want.key)
      #expect(got.value == want.value)
    }

    // Point lookups for hit and miss.
    for probe in 0..<200 {
      let key = Array("k\(probe * 13 % 2000)".utf8)
      #expect(try get(resolver, kernel.meta, key) == model.get(key))
    }
  }

  @Test func sequentialInsertsGrowDepthAndStaySorted() throws {
    let kernel = MemKernel()
    var ctx = kernel.begin()
    let count = 6000
    for i in 0..<count {
      let n = String(i)
      let key = Array(("seq-" + String(repeating: "0", count: 6 - n.count) + n).utf8)
      try put(ctx, key, Array("v\(i)".utf8))
      if i % 500 == 0 {
        kernel.commit(ctx)
        ctx = kernel.begin()
      }
    }
    kernel.commit(ctx)

    #expect(kernel.meta.treeDepth >= 2)
    let resolver = CommittedResolver(source: kernel)
    let report = try BTree.validate(resolver: resolver, meta: kernel.meta)
    #expect(report.kvCount == UInt64(count))
    #expect(report.branchCount > 0)

    let scanned = try scanAll(resolver, kernel.meta)
    #expect(scanned.count == count)
    #expect(scanned.first?.value == Array("v0".utf8))
    #expect(scanned.last?.value == Array("v\(count - 1)".utf8))
  }

  @Test func fatKeysForceDeepTree() throws {
    // Max-size keys → 4 cells per leaf, ~15 separators per branch: a few
    // hundred inserts force depth ≥ 3 and exercise branch splits hard.
    let kernel = MemKernel()
    var ctx = kernel.begin()
    var rng = SplitMix64(seed: 17)
    var model = ModelStore()
    for _ in 0..<1200 {
      let n = String(rng.next() % 1_000_000)
      var key = Array(("fat-" + String(repeating: "0", count: 6 - n.count) + n).utf8)
      key.append(contentsOf: [UInt8](repeating: 0x2E, count: Format.maxKeySize - key.count))
      let value = Array("v-\(n)".utf8)
      try put(ctx, key, value)
      model.put(key, value)
    }
    kernel.commit(ctx)

    #expect(kernel.meta.treeDepth >= 3)
    let resolver = CommittedResolver(source: kernel)
    let report = try BTree.validate(resolver: resolver, meta: kernel.meta)
    #expect(report.kvCount == UInt64(model.count))
    let scanned = try scanAll(resolver, kernel.meta)
    let expected = model.sortedPairs()
    #expect(scanned.map(\.key) == expected.map(\.key))
    #expect(scanned.map(\.value) == expected.map(\.value))
  }

  @Test func overflowValuesRoundTripAndTransition() throws {
    let kernel = MemKernel()
    let key = Array("big-one".utf8)

    // Inline → overflow → bigger overflow → back to inline.
    let stages: [[UInt8]] = [
      [UInt8](repeating: 1, count: 100),
      [UInt8](repeating: 2, count: 20_000),
      [UInt8](repeating: 3, count: 50_000),
      [UInt8](repeating: 4, count: 5),
    ]
    for stage in stages {
      let ctx = kernel.begin()
      try put(ctx, key, stage)
      kernel.commit(ctx)
      let resolver = CommittedResolver(source: kernel)
      #expect(try get(resolver, kernel.meta, key) == stage)
      _ = try BTree.validate(resolver: resolver, meta: kernel.meta)
      #expect(kernel.meta.kvCount == 1)
    }

    // After all transitions no overflow page may leak into later validates
    // (old chains were freed; MemKernel drops freed pages eagerly, so any
    // dangling reference would throw).
    let final = try BTree.validate(resolver: CommittedResolver(source: kernel), meta: kernel.meta)
    #expect(final.overflowPages == 0)
  }

  @Test func updatesPreserveCount() throws {
    let kernel = MemKernel()
    var ctx = kernel.begin()
    let key = Array("stable".utf8)
    for round in 0..<50 {
      try put(ctx, key, [UInt8](repeating: UInt8(round), count: round * 37 % 900))
    }
    kernel.commit(ctx)
    #expect(kernel.meta.kvCount == 1)
    #expect(try get(CommittedResolver(source: kernel), kernel.meta, key)?.count == 49 * 37 % 900)
  }

  @Test func keyValidation() throws {
    let kernel = MemKernel()
    let ctx = kernel.begin()
    #expect(throws: DBError.keyEmpty) {
      try put(ctx, [], [1])
    }
    #expect(throws: DBError.keyTooLarge(2000)) {
      try put(ctx, [UInt8](repeating: 1, count: 2000), [1])
    }
  }

  @Test func crossTxnCowIsolation() throws {
    // A reader holding the old meta must see the old state after new commits.
    let kernel = MemKernel()
    var ctx = kernel.begin()
    try put(ctx, Array("a".utf8), Array("old".utf8))
    kernel.commit(ctx)
    let oldMeta = kernel.meta
    // Keep old pages alive (simulating a pinned reader's epoch) by copying
    // the committed dict — MemKernel drops freed pages otherwise.
    let pinned = MemKernel()
    pinned.committed = kernel.committed
    pinned.meta = oldMeta

    ctx = kernel.begin()
    try put(ctx, Array("a".utf8), Array("new".utf8))
    try put(ctx, Array("b".utf8), Array("fresh".utf8))
    kernel.commit(ctx)

    #expect(try get(CommittedResolver(source: pinned), oldMeta, Array("a".utf8)) == Array("old".utf8))
    #expect(try get(CommittedResolver(source: pinned), oldMeta, Array("b".utf8)) == nil)
    #expect(try get(CommittedResolver(source: kernel), kernel.meta, Array("a".utf8)) == Array("new".utf8))
  }
}

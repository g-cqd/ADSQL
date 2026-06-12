import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

@Suite("FreeList codecs")
struct FreeListCodecTests {
  @Test func keyOrderIsNumeric() {
    let a = FreeList.entryKey(gen: 0, seq: 5)
    let b = FreeList.entryKey(gen: 1, seq: 0)
    let c = FreeList.entryKey(gen: 1, seq: 1)
    let d = FreeList.entryKey(gen: 256, seq: 0)
    #expect(lexicographicallyPrecedes(a, b))
    #expect(lexicographicallyPrecedes(b, c))
    #expect(lexicographicallyPrecedes(c, d))
    a.withUnsafeBytes { raw in
      let decoded = FreeList.decodeKey(raw)
      #expect(decoded?.gen == 0 && decoded?.seq == 5)
    }
    d.withUnsafeBytes { raw in
      let decoded = FreeList.decodeKey(raw)
      #expect(decoded?.gen == 256 && decoded?.seq == 0)
    }
  }

  @Test func pageListRoundTrip() throws {
    let cases: [[UInt64]] = [
      [2],
      [2, 3, 4, 5],
      [7, 100, 101, 65_000, 1 << 40, (1 << 40) + 1],
      Array(stride(from: UInt64(10), to: 810, by: 2)),
    ]
    for pages in cases {
      let encoded = FreeList.encodePages(pages[...])
      var decoded: [UInt64] = []
      var failure: DBError?
      encoded.withUnsafeBytes { raw in
        do throws(DBError) { decoded = try FreeList.decodePages(raw) } catch { failure = error }
      }
      #expect(failure == nil)
      #expect(decoded == pages)
    }
  }

  @Test func truncatedEntryIsRejected() {
    var encoded = FreeList.encodePages([5, 9, 1000][...])
    encoded.removeLast()
    var failed = false
    encoded.withUnsafeBytes { raw in
      do throws(DBError) { _ = try FreeList.decodePages(raw) } catch { failed = true }
    }
    #expect(failed)
  }
}

@Suite("FreeList lifecycle")
struct FreeListLifecycleTests {
  /// Runs the full production lifecycle against a real file and checks the
  /// liveness invariant after every commit: no leaked, no double-used pages.
  @Test func livenessInvariantAcrossChurn() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let channel = try FileChannel(path: dir.file("live.adsql"), mode: .readWrite(create: true))
    defer { channel.close() }
    var meta = try Recovery.openOrCreate(channel: channel)
    let pager = try Pager(channel: channel, maxMapSize: 1 << 30)
    let resolver = CommittedResolver(source: pager)
    var model = ModelStore()

    for txn in 0..<40 {
      let ctx = TxnContext(source: pager, meta: meta)
      try FreeList.harvest(ctx: ctx, upTo: meta.reclaimLimit(minReader: .max))
      let ops = OpScript.generate(
        seed: 0xFEED + UInt64(txn), count: 120, keySpace: 250,
        deleteRatio: 30, bigValueRatio: 6)
      for op in ops {
        try KernelOps.apply(op, ctx: ctx, model: &model)
      }
      try FreeList.serialize(ctx: ctx)
      meta = try Committer.commit(ctx: ctx, channel: channel, durability: .barrier)
      _ = try KernelOps.checkLiveness(resolver, meta)
    }

    // Contents still exact after all the reuse churn.
    let scanned = try KernelOps.scanAll(resolver, meta)
    let expected = model.sortedPairs()
    #expect(scanned.count == expected.count)
    for (got, want) in zip(scanned, expected) {
      #expect(got.key == want.key && got.value == want.value)
    }
  }

  @Test func reuseBoundsFileGrowth() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let channel = try FileChannel(path: dir.file("grow.adsql"), mode: .readWrite(create: true))
    defer { channel.close() }
    var meta = try Recovery.openOrCreate(channel: channel)
    let pager = try Pager(channel: channel, maxMapSize: 1 << 30)

    // Stable working set: the same 200 keys rewritten every transaction.
    func churn(_ rounds: Range<Int>) throws {
      for txn in rounds {
        let ctx = TxnContext(source: pager, meta: meta)
        try FreeList.harvest(ctx: ctx, upTo: meta.reclaimLimit(minReader: .max))
        for k in 0..<200 {
          try KernelOps.put(
            ctx, Array("stable-\(k)".utf8),
            [UInt8](repeating: UInt8(truncatingIfNeeded: txn &+ k), count: 120))
        }
        try FreeList.serialize(ctx: ctx)
        meta = try Committer.commit(ctx: ctx, channel: channel, durability: .barrier)
      }
    }

    try churn(0..<10)
    let early = meta.pageCount
    try churn(10..<60)
    let late = meta.pageCount

    // 50 more full-rewrite rounds over a stable working set must not grow
    // the file meaningfully — reuse has to carry the load.
    #expect(late <= early + early / 4, "pageCount grew \(early) → \(late); reuse is broken")
    _ = try KernelOps.checkLiveness(CommittedResolver(source: pager), meta)
  }

  @Test func harvestRespectsGenerationLimit() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let channel = try FileChannel(path: dir.file("limit.adsql"), mode: .readWrite(create: true))
    defer { channel.close() }
    var meta = try Recovery.openOrCreate(channel: channel)
    let pager = try Pager(channel: channel, maxMapSize: 1 << 28)

    // Txn 1: create rows. Txn 2: delete half (frees pages under gen 2).
    var ctx = TxnContext(source: pager, meta: meta)
    for i in 0..<800 {
      try KernelOps.put(ctx, Array("hl-\(i)".utf8), [UInt8](repeating: 1, count: 300))
    }
    try FreeList.serialize(ctx: ctx)
    meta = try Committer.commit(ctx: ctx, channel: channel, durability: .barrier)

    ctx = TxnContext(source: pager, meta: meta)
    try FreeList.harvest(ctx: ctx, upTo: meta.reclaimLimit(minReader: .max))
    for i in 0..<400 {
      try KernelOps.delete(ctx, Array("hl-\(i)".utf8))
    }
    try FreeList.serialize(ctx: ctx)
    meta = try Committer.commit(ctx: ctx, channel: channel, durability: .barrier)
    #expect(meta.generation == 2)

    let listed = try FreeList.allListedPages(
      resolver: CommittedResolver(source: pager), tree: meta.freeTree)
    let gen2Pages = listed.filter { $0.gen == 2 }.count
    #expect(gen2Pages > 0, "deletes must record freed pages under gen 2")

    // A pinned reader at generation 1 (limit 1) blocks gen-2 entries.
    ctx = TxnContext(source: pager, meta: meta)
    let blocked = try FreeList.harvest(ctx: ctx, upTo: 1)
    let poolAfterBlocked = ctx.allocator.pool.count
    #expect(!ctx.allocator.pool.contains { page in
      listed.contains { $0.gen == 2 && $0.page == page }
    }, "gen-2 pages must stay pinned while a gen-1 reader exists")

    // Without the pinned reader everything is harvestable.
    let ctx2 = TxnContext(source: pager, meta: meta)
    let freed = try FreeList.harvest(ctx: ctx2, upTo: meta.generation)
    #expect(freed > blocked || (freed == blocked && poolAfterBlocked == ctx2.allocator.pool.count))
    #expect(ctx2.allocator.pool.count >= gen2Pages)
  }
}

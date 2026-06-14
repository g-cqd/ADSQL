import ADSQLTestSupport
import Testing

@testable import ADSQLKernel

@Suite("Commit + reopen")
struct CommitReopenTests {
    @Test func commitsSurviveCleanReopen() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("clean.adsql")
        var model = ModelStore()

        do {
            let channel = try FileChannel(path: path, mode: .readWrite(create: true))
            var meta = try Recovery.openOrCreate(channel: channel)
            let pager = try Pager(channel: channel, maxMapSize: 1 << 30)
            for txn in 0..<6 {
                let ctx = TxnContext(source: pager, meta: meta)
                try FreeList.harvest(ctx: ctx, upTo: meta.reclaimLimit(minReader: .max))
                for op in OpScript.generate(seed: UInt64(txn), count: 300, keySpace: 500, deleteRatio: 20) {
                    try KernelOps.apply(op, ctx: ctx, model: &model)
                }
                try FreeList.serialize(ctx: ctx)
                meta = try Committer.commit(ctx: ctx, channel: channel, durability: .barrier)
                #expect(meta.generation == UInt64(txn) + 1)
            }
            channel.close()
        }

        // Fresh process simulation: reopen from disk only.
        let channel = try FileChannel(path: path, mode: .readWrite(create: true))
        defer { channel.close() }
        let meta = try Recovery.openOrCreate(channel: channel)
        #expect(meta.generation == 6)
        let pager = try Pager(channel: channel, maxMapSize: 1 << 30)
        let resolver = CommittedResolver(source: pager)
        _ = try BTree.validate(resolver: resolver, meta: meta, verifyChecksums: true)
        _ = try KernelOps.checkLiveness(resolver, meta)

        let scanned = try KernelOps.scanAll(resolver, meta)
        let expected = model.sortedPairs()
        #expect(scanned.count == expected.count)
        for (got, want) in zip(scanned, expected) {
            #expect(got.key == want.key && got.value == want.value)
        }
    }

    @Test func emptyTransactionIsNoOp() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let channel = try FileChannel(path: dir.file("noop.adsql"), mode: .readWrite(create: true))
        defer { channel.close() }
        let meta = try Recovery.openOrCreate(channel: channel)
        let pager = try Pager(channel: channel, maxMapSize: 1 << 24)
        let ctx = TxnContext(source: pager, meta: meta)
        let after = try Committer.commit(ctx: ctx, channel: channel, durability: .barrier)
        #expect(after == meta)
        #expect(after.generation == 0)
    }

    @Test func corruptedDataPageIsDetectedByChecksum() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("corrupt.adsql")
        let channel = try FileChannel(path: path, mode: .readWrite(create: true))
        defer { channel.close() }
        var meta = try Recovery.openOrCreate(channel: channel)
        let pager = try Pager(channel: channel, maxMapSize: 1 << 26)
        let ctx = TxnContext(source: pager, meta: meta)
        for i in 0..<500 {
            try KernelOps.put(ctx, Array("ck\(i)".utf8), [UInt8](repeating: 9, count: 200))
        }
        meta = try Committer.commit(ctx: ctx, channel: channel, durability: .barrier)

        // Flip one byte inside the root page body.
        let rootOffset = Int(meta.rootPage) * Format.pageSize
        var byte = try channel.preadBytes(count: 1, at: rootOffset + 5000)
        byte[0] ^= 0x10
        try channel.pwrite(byte, at: rootOffset + 5000)

        #expect(throws: DBError.corruptPage(pageNo: meta.rootPage)) {
            _ = try BTree.validate(
                resolver: CommittedResolver(source: pager), meta: meta, verifyChecksums: true)
        }
    }

    @Test func tornNewestMetaFallsBackOneGeneration() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("torn.adsql")
        let channel = try FileChannel(path: path, mode: .readWrite(create: true))
        defer { channel.close() }
        var meta = try Recovery.openOrCreate(channel: channel)
        let pager = try Pager(channel: channel, maxMapSize: 1 << 26)
        for round in 0..<3 {
            let ctx = TxnContext(source: pager, meta: meta)
            try KernelOps.put(ctx, Array("gen".utf8), [UInt8(round)])
            meta = try Committer.commit(ctx: ctx, channel: channel, durability: .barrier)
        }
        #expect(meta.generation == 3)

        // Corrupt the newest meta (generation 3 lives on page 3 % 2 = 1).
        var bytes = try channel.preadBytes(count: 64, at: Format.pageSize + 40)
        bytes[0] ^= 0xFF
        try channel.pwrite(bytes, at: Format.pageSize + 40)

        let recovered = try Recovery.openOrCreate(channel: channel)
        #expect(recovered.generation == 2)
    }
}

@Suite("Crash injection")
struct CrashInjectionTests {
    struct History {
        var modelByGeneration: [UInt64: ModelStore] = [:]
        var lastGeneration: UInt64 = 0
    }

    /// Runs `txnCount` committed transactions against a SimulatedDisk and
    /// records the model at every generation.
    func buildHistory(
        disk: SimulatedDisk, durability: DurabilityProfile, txnCount: Int, opsPerTxn: Int
    ) throws -> History {
        var history = History()
        var model = ModelStore()
        var meta = try Recovery.openOrCreate(channel: disk)
        history.modelByGeneration[0] = model
        let pager = try Pager(channel: disk, maxMapSize: 1 << 30)

        for txn in 0..<txnCount {
            let ctx = TxnContext(source: pager, meta: meta)
            // Full production lifecycle: harvest, mutate, serialize, commit —
            // page reuse under crash is exactly what this harness must prove safe.
            try FreeList.harvest(ctx: ctx, upTo: meta.reclaimLimit(minReader: .max))
            let ops = OpScript.generate(
                seed: 0xC0FFEE + UInt64(txn), count: opsPerTxn, keySpace: 300,
                deleteRatio: 25, bigValueRatio: 5)
            for op in ops {
                try KernelOps.apply(op, ctx: ctx, model: &model)
            }
            try FreeList.serialize(ctx: ctx)
            meta = try Committer.commit(ctx: ctx, channel: disk, durability: durability)
            history.modelByGeneration[meta.generation] = model
            history.lastGeneration = meta.generation
        }
        return history
    }

    /// Reopens a crash image and checks the crash-consistency invariant:
    /// the recovered state IS some committed generation, bit-for-bit.
    func assertRecovers(
        image: [UInt8], disk: SimulatedDisk, dir: TempDir, name: String, history: History
    ) throws -> UInt64 {
        let path = dir.file(name)
        try disk.writeCrashImage(image, to: path)
        let channel = try FileChannel(path: path, mode: .readWrite(create: true))
        defer { channel.close() }

        let meta = try Recovery.openOrCreate(channel: channel, createIfMissing: false)
        guard let expected = history.modelByGeneration[meta.generation] else {
            Issue.record("recovered unknown generation \(meta.generation)")
            return meta.generation
        }
        let pager = try Pager(channel: channel, maxMapSize: 1 << 30)
        let resolver = CommittedResolver(source: pager)
        _ = try BTree.validate(resolver: resolver, meta: meta, verifyChecksums: true)
        _ = try KernelOps.checkLiveness(resolver, meta)

        let scanned = try KernelOps.scanAll(resolver, meta)
        let want = expected.sortedPairs()
        #expect(scanned.count == want.count, "gen \(meta.generation) content mismatch")
        for (got, wanted) in zip(scanned, want) {
            if got.key != wanted.key || got.value != wanted.value {
                Issue.record("content mismatch at gen \(meta.generation)")
                break
            }
        }
        return meta.generation
    }

    @Test func barrierProfileSweepEveryCutGroup() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let disk = try SimulatedDisk(path: dir.file("sweep.adsql"))
        defer { disk.close() }
        let history = try buildHistory(disk: disk, durability: .barrier, txnCount: 8, opsPerTxn: 120)

        var recoveredGens = Set<UInt64>()
        var caseIndex = 0
        for cutGroup in disk.crashCutGroups {
            for tearSeed: UInt64 in 0..<6 {
                let image = disk.materializeCrashImage(cutGroup: cutGroup, tearSeed: tearSeed)
                let gen = try assertRecovers(
                    image: image, disk: disk, dir: dir, name: "cut-\(caseIndex).adsql", history: history)
                recoveredGens.insert(gen)
                caseIndex += 1
            }
        }

        // The sweep must actually exercise intermediate generations, and a cut
        // after the final group (writeback fully drained) must recover the
        // last commit.
        #expect(recoveredGens.count > 2, "sweep should land on multiple generations")
        let finalImage = disk.materializeCrashImage(
            cutGroup: disk.crashCutGroups.upperBound + 1, tearSeed: 1)
        let finalGen = try assertRecovers(
            image: finalImage, disk: disk, dir: dir, name: "cut-final.adsql", history: history)
        #expect(finalGen == history.lastGeneration)
    }

    @Test func fullProfileNeverLosesCommits() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let disk = try SimulatedDisk(path: dir.file("full.adsql"))
        defer { disk.close() }
        let history = try buildHistory(disk: disk, durability: .full, txnCount: 5, opsPerTxn: 80)

        // F_FULLFSYNC pins the durable floor at every commit: any crash recovers
        // exactly the last generation.
        for seed: UInt64 in 0..<12 {
            let image = disk.materializeCrashImage(seed: seed)
            let gen = try assertRecovers(
                image: image, disk: disk, dir: dir, name: "full-\(seed).adsql", history: history)
            #expect(gen == history.lastGeneration)
        }
    }

    @Test func randomizedCrashStorm() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let disk = try SimulatedDisk(path: dir.file("storm.adsql"))
        defer { disk.close() }
        let history = try buildHistory(disk: disk, durability: .barrier, txnCount: 10, opsPerTxn: 60)

        for seed: UInt64 in 0..<60 {
            let image = disk.materializeCrashImage(seed: seed)
            _ = try assertRecovers(
                image: image, disk: disk, dir: dir, name: "storm-\(seed).adsql", history: history)
        }
    }
}

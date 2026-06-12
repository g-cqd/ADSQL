import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

private func put(_ ctx: TxnContext, _ key: [UInt8], _ value: [UInt8]) throws {
  var failure: DBError?
  key.withUnsafeBytes { k in
    value.withUnsafeBytes { v in
      do throws(DBError) { try BTree.put(ctx: ctx, key: k, value: v) } catch { failure = error }
    }
  }
  if let failure { throw failure }
}

private func del(_ ctx: TxnContext, _ key: [UInt8]) throws -> Bool {
  var result: Result<Bool, DBError> = .success(false)
  key.withUnsafeBytes { k in
    do throws(DBError) { result = .success(try BTree.delete(ctx: ctx, key: k)) } catch {
      result = .failure(error)
    }
  }
  return try result.get()
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

@Suite("BTree delete")
struct BTreeDeleteTests {
  @Test(arguments: [UInt64(3), 11, 77, 4242])
  func mixedOpsMatchModel(seed: UInt64) throws {
    let kernel = MemKernel()
    var model = ModelStore()
    let ops = OpScript.generate(
      seed: seed, count: 5000, keySpace: 600, deleteRatio: 35, bigValueRatio: 4)

    var ctx = kernel.begin()
    for (i, op) in ops.enumerated() {
      switch op {
      case .put(let key, let value):
        try put(ctx, key, value)
        model.put(key, value)
      case .delete(let key):
        let existed = model.delete(key)
        #expect(try del(ctx, key) == existed)
      }
      if i % 313 == 0 {
        kernel.commit(ctx)
        _ = try BTree.validate(resolver: CommittedResolver(source: kernel), meta: kernel.meta)
        ctx = kernel.begin()
      }
    }
    kernel.commit(ctx)

    let resolver = CommittedResolver(source: kernel)
    let report = try BTree.validate(resolver: resolver, meta: kernel.meta)
    #expect(report.kvCount == UInt64(model.count))

    var scanned: [(key: [UInt8], value: [UInt8])] = []
    try BTree.forEach(resolver: resolver, meta: kernel.meta) { (key, ref) throws(DBError) in
      scanned.append((key: [UInt8](key), value: try BTree.copyValue(ref, resolver: resolver)))
    }
    let expected = model.sortedPairs()
    #expect(scanned.count == expected.count)
    for (got, want) in zip(scanned, expected) {
      #expect(got.key == want.key && got.value == want.value)
    }
  }

  @Test func deleteEverythingEmptiesTree() throws {
    let kernel = MemKernel()
    var ctx = kernel.begin()
    var keys: [[UInt8]] = []
    for i in 0..<3000 {
      let key = Array("wipe-\(i)".utf8)
      try put(ctx, key, [UInt8](repeating: 1, count: 64))
      keys.append(key)
    }
    kernel.commit(ctx)

    var rng = SplitMix64(seed: 9)
    keys.shuffle(using: &rng)
    ctx = kernel.begin()
    for (i, key) in keys.enumerated() {
      #expect(try del(ctx, key))
      if i % 500 == 0 {
        kernel.commit(ctx)
        _ = try BTree.validate(resolver: CommittedResolver(source: kernel), meta: kernel.meta)
        ctx = kernel.begin()
      }
    }
    kernel.commit(ctx)

    #expect(kernel.meta.rootPage == 0)
    #expect(kernel.meta.treeDepth == 0)
    #expect(kernel.meta.kvCount == 0)
    // Deleting from the empty tree is a clean miss.
    ctx = kernel.begin()
    #expect(try !del(ctx, keys[0]))
  }

  @Test func deepTreeCollapsesOnMassDelete() throws {
    let kernel = MemKernel()
    var ctx = kernel.begin()
    var keys: [[UInt8]] = []
    for i in 0..<1200 {
      let n = String(i)
      var key = Array(("deep-" + String(repeating: "0", count: 5 - n.count) + n).utf8)
      key.append(contentsOf: [UInt8](repeating: 0x2D, count: Format.maxKeySize - key.count))
      try put(ctx, key, Array("v\(i)".utf8))
      keys.append(key)
    }
    kernel.commit(ctx)
    let deepDepth = kernel.meta.treeDepth
    #expect(deepDepth >= 3)

    ctx = kernel.begin()
    for key in keys.dropLast(20) {
      #expect(try del(ctx, key))
    }
    kernel.commit(ctx)

    #expect(kernel.meta.treeDepth < deepDepth)
    #expect(kernel.meta.kvCount == 20)
    let resolver = CommittedResolver(source: kernel)
    _ = try BTree.validate(resolver: resolver, meta: kernel.meta)
    for key in keys.suffix(20) {
      #expect(try get(resolver, kernel.meta, key) != nil)
    }
  }

  @Test func deleteFreesOverflowChains() throws {
    let kernel = MemKernel()
    var ctx = kernel.begin()
    try put(ctx, Array("blob".utf8), [UInt8](repeating: 8, count: 60_000))
    try put(ctx, Array("keep".utf8), [2])
    kernel.commit(ctx)
    let withBlob = try BTree.validate(
      resolver: CommittedResolver(source: kernel), meta: kernel.meta)
    #expect(withBlob.overflowPages == 4)

    ctx = kernel.begin()
    #expect(try del(ctx, Array("blob".utf8)))
    kernel.commit(ctx)
    let after = try BTree.validate(
      resolver: CommittedResolver(source: kernel), meta: kernel.meta)
    #expect(after.overflowPages == 0)
    #expect(after.kvCount == 1)
  }
}

@Suite("Cursor")
struct CursorTests {
  func buildTree(seed: UInt64, count: Int) throws -> (MemKernel, ModelStore) {
    let kernel = MemKernel()
    var model = ModelStore()
    let ctx = kernel.begin()
    var rng = SplitMix64(seed: seed)
    for _ in 0..<count {
      let key = Array("c\(rng.next() % 50_000)".utf8)
      let value = [UInt8](repeating: UInt8(truncatingIfNeeded: rng.next()), count: Int(rng.next() % 120))
      try put(ctx, key, value)
      model.put(key, value)
    }
    kernel.commit(ctx)
    return (kernel, model)
  }

  @Test func forwardScanMatchesModel() throws {
    let (kernel, model) = try buildTree(seed: 21, count: 3000)
    var cursor = Cursor(resolver: CommittedResolver(source: kernel), meta: kernel.meta)
    var scanned: [(key: [UInt8], value: [UInt8])] = []
    if try cursor.move(to: .first) {
      repeat {
        let key = try cursor.currentKey()!
        let value = try cursor.currentValue()!
        scanned.append((key, value))
      } while try cursor.next()
    }
    let expected = model.sortedPairs()
    #expect(scanned.count == expected.count)
    for (got, want) in zip(scanned, expected) {
      #expect(got.key == want.key && got.value == want.value)
    }
  }

  @Test func reverseScanMatchesModel() throws {
    let (kernel, model) = try buildTree(seed: 22, count: 2000)
    var cursor = Cursor(resolver: CommittedResolver(source: kernel), meta: kernel.meta)
    var scanned: [[UInt8]] = []
    if try cursor.move(to: .last) {
      repeat {
        scanned.append(try cursor.currentKey()!)
      } while try cursor.prev()
    }
    let expected = model.sortedPairs().map(\.key).reversed()
    #expect(scanned == Array(expected))
  }

  @Test func seekSemantics() throws {
    let kernel = MemKernel()
    let ctx = kernel.begin()
    for i in stride(from: 0, to: 100, by: 10) {
      let n = String(i)
      try put(ctx, Array(("s" + String(repeating: "0", count: 3 - n.count) + n).utf8), [UInt8(i)])
    }
    kernel.commit(ctx)
    var cursor = Cursor(resolver: CommittedResolver(source: kernel), meta: kernel.meta)

    // Exact hit.
    var exact = false
    Array("s050".utf8).withUnsafeBytes { exact = (try? cursor.seek($0)) ?? false }
    #expect(exact)
    #expect(try cursor.currentKey() == Array("s050".utf8))

    // Miss positions at lower bound.
    Array("s055".utf8).withUnsafeBytes { exact = (try? cursor.seek($0)) ?? true }
    #expect(!exact)
    var valid = cursor.isValid
    #expect(valid)
    #expect(try cursor.currentKey() == Array("s060".utf8))

    // Before the first key.
    Array("a".utf8).withUnsafeBytes { exact = (try? cursor.seek($0)) ?? true }
    valid = cursor.isValid
    #expect(!exact && valid)
    #expect(try cursor.currentKey() == Array("s000".utf8))

    // Past the last key.
    Array("zzz".utf8).withUnsafeBytes { exact = (try? cursor.seek($0)) ?? true }
    #expect(!exact)
    valid = cursor.isValid
    #expect(!valid)
    #expect(try cursor.currentKey() == nil)
  }

  @Test func seekAcrossLeavesInDeepTree() throws {
    // Fat keys force depth ≥ 3 so lower-bound hops cross leaf boundaries.
    let kernel = MemKernel()
    let ctx = kernel.begin()
    var keys: [[UInt8]] = []
    for i in 0..<800 {
      let n = String(i * 2) // even values only
      var key = Array(("gap-" + String(repeating: "0", count: 4 - n.count) + n).utf8)
      key.append(contentsOf: [UInt8](repeating: 0x5F, count: Format.maxKeySize - key.count))
      try put(ctx, key, Array("\(i)".utf8))
      keys.append(key)
    }
    kernel.commit(ctx)
    #expect(kernel.meta.treeDepth >= 3)

    var cursor = Cursor(resolver: CommittedResolver(source: kernel), meta: kernel.meta)
    var rng = SplitMix64(seed: 33)
    for _ in 0..<100 {
      let target = Int(rng.next() % 1600) // odd values miss
      let n = String(target)
      var probe = Array(("gap-" + String(repeating: "0", count: max(0, 4 - n.count)) + n).utf8)
      probe.append(contentsOf: [UInt8](repeating: 0x5F, count: Format.maxKeySize - probe.count))

      var exact = false
      probe.withUnsafeBytes { exact = (try? cursor.seek($0)) ?? false }
      let expectedIndex = keys.firstIndex { !lexicographicallyPrecedes($0, probe) }
      let valid = cursor.isValid
      if let expectedIndex {
        #expect(valid)
        #expect(try cursor.currentKey() == keys[expectedIndex])
        #expect(exact == (keys[expectedIndex] == probe))
      } else {
        #expect(!valid)
      }
    }
  }

  @Test func emptyTreeCursor() throws {
    let kernel = MemKernel()
    var cursor = Cursor(resolver: CommittedResolver(source: kernel), meta: kernel.meta)
    #expect(try !cursor.move(to: .first))
    #expect(try !cursor.move(to: .last))
    #expect(try cursor.currentKey() == nil)
    var exact = true
    Array("x".utf8).withUnsafeBytes { exact = (try? cursor.seek($0)) ?? true }
    let valid = cursor.isValid
    #expect(!exact && !valid)
  }
}

import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

private func key(_ s: String) -> [UInt8] { Array(s.utf8) }

private func pad(_ n: UInt64, _ width: Int) -> String {
  let s = String(n)
  return String(repeating: "0", count: max(0, width - s.count)) + s
}

private func leafInsert(_ page: PageBuf, _ key: [UInt8], _ value: [UInt8]) -> Bool {
  key.withUnsafeBytes { k in
    value.withUnsafeBytes { v in
      let (index, exact) = Node.search(page.readOnly, key: k)
      precondition(!exact, "test helper expects fresh keys")
      return Node.leafInsert(page.raw, at: index, key: k, value: .inline(v))
    }
  }
}

private func leafLookup(_ page: PageBuf, _ key: [UInt8]) -> [UInt8]? {
  key.withUnsafeBytes { k in
    let (index, exact) = Node.search(page.readOnly, key: k)
    guard exact else { return nil }
    let cell = Node.leafCell(page.readOnly, index)
    return cell.inlineValue.map { [UInt8]($0) }
  }
}

@Suite("Node leaf ops")
struct NodeLeafTests {
  @Test func insertSearchRemoveAgainstModel() {
    let page = PageBuf()
    PageHeader.initialize(page.raw, type: .leaf)
    var model = ModelStore()
    var rng = SplitMix64(seed: 1)

    // Fill with random short keys until the page refuses (split signal).
    var inserted = 0
    while true {
      let k = key("k\(rng.next() % 100_000)")
      if model.get(k) != nil { continue }
      let v = [UInt8](repeating: UInt8(truncatingIfNeeded: rng.next()), count: Int(rng.next() % 64))
      if !leafInsert(page, k, v) { break }
      model.put(k, v)
      inserted += 1
    }
    #expect(inserted > 200) // short cells → packs densely

    // Every model entry must be present and in slot order.
    for (k, v) in model.sortedPairs() {
      #expect(leafLookup(page, k) == v)
    }
    let count = PageHeader.cellCount(page.readOnly)
    #expect(count == model.count)
    for i in 1..<count {
      #expect(Node.compare(Node.nodeKey(page.readOnly, i - 1), Node.nodeKey(page.readOnly, i)) < 0)
    }

    // Remove half, verify the rest.
    let pairs = model.sortedPairs()
    for (i, pair) in pairs.enumerated() where i % 2 == 0 {
      pair.key.withUnsafeBytes { k in
        let (index, exact) = Node.search(page.readOnly, key: k)
        #expect(exact)
        Node.removeCell(page.raw, at: index)
      }
      model.delete(pair.key)
    }
    for (i, pair) in pairs.enumerated() {
      #expect(leafLookup(page, pair.key) == (i % 2 == 0 ? nil : pair.value))
    }
  }

  @Test func fragmentationThenCompactionReclaims() {
    let page = PageBuf()
    PageHeader.initialize(page.raw, type: .leaf)
    // Two big cells + one small, remove a big one in the middle of the area.
    let big = [UInt8](repeating: 7, count: 3000)
    #expect(leafInsert(page, key("aaa"), big))
    #expect(leafInsert(page, key("bbb"), big))
    #expect(leafInsert(page, key("ccc"), [1]))

    key("bbb").withUnsafeBytes { k in
      let (index, exact) = Node.search(page.readOnly, key: k)
      #expect(exact)
      Node.removeCell(page.raw, at: index)
    }
    #expect(PageHeader.fragmentedBytes(page.readOnly) > 2900)

    // An insert larger than contiguous free space (but coverable with the
    // fragmented bytes) must succeed via in-page compaction.
    let huge = 10_400
    #expect(PageHeader.freeSpace(page.readOnly) < huge + 7)
    #expect(leafInsert(page, key("ddd"), [UInt8](repeating: 9, count: huge)))
    #expect(PageHeader.fragmentedBytes(page.readOnly) == 0)
    #expect(leafLookup(page, key("aaa")) == big)
    #expect(leafLookup(page, key("ccc")) == [1])
    #expect(leafLookup(page, key("ddd"))?.count == huge)
  }

  @Test func minimumFourMaxCellsPerLeaf() {
    let page = PageBuf()
    PageHeader.initialize(page.raw, type: .leaf)
    // Worst-case inline cells (4064 bytes total each) — four must fit.
    let value = [UInt8](repeating: 1, count: Format.maxInlineCellSize - 5 - 4)
    for i in 0..<4 {
      #expect(leafInsert(page, key("k\(i)\(String(repeating: "x", count: 1))"), value))
    }
    #expect(PageHeader.cellCount(page.readOnly) == 4)
  }

  @Test func splitKeepsAllCellsSortedAndSeparatorCorrect() {
    let page = PageBuf()
    PageHeader.initialize(page.raw, type: .leaf)
    var model = ModelStore()
    var rng = SplitMix64(seed: 99)
    var pendingKey: [UInt8] = []
    var pendingValue: [UInt8] = []
    while true {
      let k = key("key-" + pad(rng.next() % 100_000_000, 8))
      if model.get(k) != nil { continue }
      let v = [UInt8](repeating: 3, count: 40 + Int(rng.next() % 400))
      if !leafInsert(page, k, v) {
        pendingKey = k
        pendingValue = v
        break
      }
      model.put(k, v)
    }

    let left = PageBuf()
    let right = PageBuf()
    let separator = pendingKey.withUnsafeBytes { k in
      pendingValue.withUnsafeBytes { v in
        let (index, _) = Node.search(page.readOnly, key: k)
        return Node.splitLeafInserting(
          original: page.readOnly, at: index, key: k, value: .inline(v),
          left: left.raw, right: right.raw)
      }
    }
    model.put(pendingKey, pendingValue)

    // Both sides non-trivially populated.
    let leftCount = PageHeader.cellCount(left.readOnly)
    let rightCount = PageHeader.cellCount(right.readOnly)
    #expect(leftCount > 0 && rightCount > 0)
    #expect(leftCount + rightCount == model.count)

    // Separator is exactly the first right key, and partitions the sides.
    #expect([UInt8](Node.nodeKey(right.readOnly, 0)) == separator)
    #expect(Node.compare(Node.nodeKey(left.readOnly, leftCount - 1), Node.nodeKey(right.readOnly, 0)) < 0)

    // Every entry still readable from the correct side.
    for (k, v) in model.sortedPairs() {
      let side = lexicographicallyPrecedes(k, separator) ? left : right
      #expect(leafLookup(side, k) == v, "key \(String(decoding: k, as: UTF8.self))")
    }
  }

  @Test func splitLeftMayAliasOriginal() {
    let page = PageBuf()
    PageHeader.initialize(page.raw, type: .leaf)
    var keys: [[UInt8]] = []
    var rng = SplitMix64(seed: 5)
    while true {
      let k = key(pad(rng.next() % 1_000_000, 6))
      if keys.contains(k) { continue }
      if !leafInsert(page, k, [UInt8](repeating: 1, count: 200)) { break }
      keys.append(k)
    }
    let right = PageBuf()
    let newKey = key("zzzzzzz")
    let separator = newKey.withUnsafeBytes { k in
      [UInt8]([9, 9]).withUnsafeBytes { v in
        let (index, _) = Node.search(page.readOnly, key: k)
        // left aliases the original buffer — must be safe.
        return Node.splitLeafInserting(
          original: page.readOnly, at: index, key: k, value: .inline(v),
          left: page.raw, right: right.raw)
      }
    }
    let total = PageHeader.cellCount(page.readOnly) + PageHeader.cellCount(right.readOnly)
    #expect(total == keys.count + 1)
    #expect(!separator.isEmpty)
    for k in keys {
      let side = lexicographicallyPrecedes(k, separator) ? page : right
      #expect(leafLookup(side, k) != nil)
    }
    #expect(leafLookup(right, newKey) == [9, 9])
  }
}

@Suite("Node branch ops")
struct NodeBranchTests {
  func makeBranch(_ separators: [(String, UInt64)], leftmost: UInt64) -> PageBuf {
    let page = PageBuf()
    PageHeader.initialize(page.raw, type: .branch)
    PageHeader.setLink(page.raw, leftmost)
    for (k, child) in separators {
      key(k).withUnsafeBytes { kb in
        let (index, exact) = Node.search(page.readOnly, key: kb)
        precondition(!exact)
        #expect(Node.branchInsert(page.raw, at: index, key: kb, child: child))
      }
    }
    return page
  }

  @Test func descentTargets() {
    // leftmost=10 | "g"→11 | "p"→12
    let page = makeBranch([("g", 11), ("p", 12)], leftmost: 10)
    func target(_ s: String) -> UInt64 {
      key(s).withUnsafeBytes { Node.descendTarget(page.readOnly, key: $0) }
    }
    #expect(target("a") == 10) // < "g"
    #expect(target("g") == 11) // == separator → right side of it
    #expect(target("k") == 11)
    #expect(target("p") == 12)
    #expect(target("z") == 12)
  }

  @Test func setChildInPlace() {
    let page = makeBranch([("g", 11), ("p", 12)], leftmost: 10)
    Node.branchSetChild(page.raw, at: 1, child: 99)
    #expect(Node.branchChild(page.readOnly, 1) == 99)
    #expect(Node.branchChild(page.readOnly, 0) == 11)
    #expect(PageHeader.link(page.readOnly) == 10)
  }

  @Test func branchSplitPromotesMiddleKey() {
    let page = PageBuf()
    PageHeader.initialize(page.raw, type: .branch)
    PageHeader.setLink(page.raw, 1000)
    var n: UInt64 = 0
    var lastKey = ""
    while true {
      let k = "sep-" + pad(n * 2, 6)
      let ok = key(k).withUnsafeBytes { kb in
        let (index, exact) = Node.search(page.readOnly, key: kb)
        precondition(!exact)
        return Node.branchInsert(page.raw, at: index, key: kb, child: 2000 + n)
      }
      if !ok {
        lastKey = k
        break
      }
      n += 1
    }

    let left = PageBuf()
    let right = PageBuf()
    let separator = key(lastKey).withUnsafeBytes { kb in
      let (index, _) = Node.search(page.readOnly, key: kb)
      return Node.splitBranchInserting(
        original: page.readOnly, at: index, key: kb, child: 2000 + n,
        left: left.raw, right: right.raw)
    }

    let leftCount = PageHeader.cellCount(left.readOnly)
    let rightCount = PageHeader.cellCount(right.readOnly)
    // Middle cell was promoted, not stored.
    #expect(leftCount + rightCount == Int(n))
    #expect(PageHeader.link(left.readOnly) == 1000)

    // The promoted separator's child became right's leftmost child:
    // descending right for a key just above the separator hits it.
    let promotedChild = PageHeader.link(right.readOnly)
    #expect(promotedChild != 0)
    let probe = separator + [0]
    let hit = probe.withUnsafeBytes { Node.descendTarget(right.readOnly, key: $0) }
    #expect(hit == promotedChild)

    // All keys on the left precede the separator; all on the right follow it.
    separator.withUnsafeBytes { sep in
      #expect(Node.compare(Node.nodeKey(left.readOnly, leftCount - 1), sep) < 0)
      #expect(Node.compare(sep, Node.nodeKey(right.readOnly, 0)) < 0)
    }
  }
}

@Suite("Overflow chains")
struct OverflowTests {
  final class DictPager: OverflowPager {
    var pages: [UInt64: PageBuf] = [:]
    var nextPage: UInt64 = 100
    var freed: [UInt64] = []

    func allocateOverflowPage() throws(DBError) -> (pageNo: UInt64, buffer: UnsafeMutableRawBufferPointer) {
      let buf = PageBuf()
      let no = nextPage
      nextPage += 1
      pages[no] = buf
      return (no, buf.raw)
    }
    func readOverflowPage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
      guard let buf = pages[pageNo] else { throw DBError.corruptPage(pageNo: pageNo) }
      return buf.readOnly
    }
    func freeOverflowPage(_ pageNo: UInt64) throws(DBError) {
      precondition(pages[pageNo] != nil)
      pages[pageNo] = nil
      freed.append(pageNo)
    }
  }

  @Test(arguments: [1, 4000, Format.overflowCapacity, Format.overflowCapacity + 1, 40_000])
  func roundTrip(_ length: Int) throws {
    var pager = DictPager()
    let value = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 13) }
    var head: UInt64 = 0
    value.withUnsafeBytes { raw in
      head = try! Overflow.write(raw, pager: &pager)
    }
    #expect(pager.pages.count == Overflow.pageCount(forLength: length))
    let back = try Overflow.read(head: head, length: length, pager: pager)
    #expect(back == value)

    // Chunked visiting sees identical bytes.
    var chunked: [UInt8] = []
    try Overflow.withChunks(head: head, length: length, pager: pager) { chunked.append(contentsOf: $0) }
    #expect(chunked == value)

    try Overflow.free(head: head, pager: &pager)
    #expect(pager.pages.isEmpty)
    #expect(pager.freed.count == Overflow.pageCount(forLength: length))
  }

  @Test func corruptChainIsDetected() throws {
    var pager = DictPager()
    let value = [UInt8](repeating: 5, count: Format.overflowCapacity * 2)
    var head: UInt64 = 0
    value.withUnsafeBytes { raw in head = try! Overflow.write(raw, pager: &pager) }
    // Break the chain: second page vanishes.
    let second = PageHeader.link(try pager.readOverflowPage(head))
    pager.pages[second] = nil
    #expect(throws: DBError.self) {
      _ = try Overflow.read(head: head, length: value.count, pager: pager)
    }
  }

  @Test func truncatedChainLengthMismatchIsDetected() throws {
    var pager = DictPager()
    let value = [UInt8](repeating: 6, count: 100)
    var head: UInt64 = 0
    value.withUnsafeBytes { raw in head = try! Overflow.write(raw, pager: &pager) }
    #expect(throws: DBError.corruptPage(pageNo: head)) {
      _ = try Overflow.read(head: head, length: 200, pager: pager)
    }
  }
}

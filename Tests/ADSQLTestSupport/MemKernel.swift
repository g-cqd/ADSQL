import ADSQLKernel

/// In-memory committed-page store: lets B+tree logic run without the pager /
/// committer. Freed pages are dropped eagerly so any dangling reference from
/// a later transaction throws instead of silently reading stale bytes.
package final class MemKernel: PageSource {
  package var committed: [UInt64: PageBuf] = [:]
  package var meta: Meta = .empty

  package init() {}

  package func page(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
    guard let buf = committed[pageNo] else { throw DBError.corruptPage(pageNo: pageNo) }
    return buf.readOnly
  }

  package func begin() -> TxnContext {
    TxnContext(source: self, meta: meta)
  }

  package func commit(_ ctx: TxnContext) {
    for (pageNo, buf) in ctx.dirty { committed[pageNo] = buf }
    for pageNo in ctx.pendingFree { committed.removeValue(forKey: pageNo) }
    var next = ctx.meta
    next.pageCount = ctx.allocator.highWater
    next.generation += 1
    meta = next
  }
}

/// Deterministic operation scripts shared by model tests and the crash
/// harness.
package enum DBOp: Sendable, Equatable {
  case put(key: [UInt8], value: [UInt8])
  case delete(key: [UInt8])
}

package enum OpScript {
  package static func generate(
    seed: UInt64, count: Int, keySpace: UInt64 = 5000,
    deleteRatio: UInt64 = 0, bigValueRatio: UInt64 = 3
  ) -> [DBOp] {
    var rng = SplitMix64(seed: seed)
    var ops: [DBOp] = []
    ops.reserveCapacity(count)
    for _ in 0..<count {
      let key = Array("k\(rng.next() % keySpace)".utf8)
      if rng.next() % 100 < deleteRatio {
        ops.append(.delete(key: key))
        continue
      }
      let size: Int
      if rng.next() % 100 < bigValueRatio {
        size = 5_000 + Int(rng.next() % 35_000) // overflow chains
      } else {
        size = Int(rng.next() % 257)
      }
      let fill = UInt8(truncatingIfNeeded: rng.next())
      var value = [UInt8](repeating: fill, count: size)
      // Stamp the key into the value head so misdirected reads are caught.
      for (i, b) in key.enumerated() where i < value.count { value[i] = b }
      ops.append(.put(key: key, value: value))
    }
    return ops
  }
}

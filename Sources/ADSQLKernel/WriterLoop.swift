import Dispatch
import Synchronization

/// Group commit: concurrent `write` calls coalesce into batches that share
/// one transaction context and one durability point. Each request is a
/// *stacked micro-transaction*: it builds on the in-memory state left by the
/// previous request; if it throws, only its own delta is rolled back (cheap
/// state snapshot), and earlier successes still commit.
///
/// Callers resume only after their data is durable per the database's
/// profile — a returned `write` IS a committed write.
extension Database {
  struct PendingWrite: @unchecked Sendable {
    /// Runs the user body against the shared context. On success returns a
    /// completion taking the eventual commit outcome (nil = committed); on
    /// a body throw the request resumes itself and returns nil.
    let attempt: (TxnContext) -> ((DBError?) -> Void)?
    /// Fails the request without ever running its body.
    let fail: (DBError) -> Void
  }

  /// Submits a write transaction for group commit.
  public func write<R: Sendable>(
    _ body: @escaping @Sendable (borrowing WriteTxn) throws(DBError) -> R
  ) async throws(DBError) -> R {
    guard !options.readOnly else { throw DBError.readOnlyDatabase }
    let outcome: Result<R, DBError> = await withCheckedContinuation { continuation in
      enqueue(
        PendingWrite(
          attempt: { ctx in
            do throws(DBError) {
              let txn = WriteTxn(ctx: ctx)
              let value = try body(txn)
              return { commitError in
                continuation.resume(
                  returning: commitError.map { .failure($0) } ?? .success(value))
              }
            } catch {
              continuation.resume(returning: .failure(error))
              return nil
            }
          },
          fail: { error in
            continuation.resume(returning: .failure(error))
          }))
    }
    return try outcome.get()
  }

  func enqueue(_ item: PendingWrite) {
    let scheduleDrain: Bool = pendingWrites.withLock { queue in
      queue.append(item)
      return queue.count == 1
    }
    if scheduleDrain {
      writeQueue.async { [self] in drainPendingWrites() }
    }
  }

  /// Runs on the serial writer queue (mutually exclusive with `writeSync`).
  private func drainPendingWrites() {
    let maxBatchRequests = 128

    while true {
      let batch: [PendingWrite] = pendingWrites.withLock { queue in
        let take = min(queue.count, maxBatchRequests)
        let slice = Array(queue.prefix(take))
        queue.removeFirst(take)
        return slice
      }
      if batch.isEmpty { return }

      let snapshot: (Meta, UInt64)? = shared.withLock { state in
        guard !state.closed else { return nil }
        let minReader = state.readers.keys.min() ?? state.meta.generation
        return (state.meta, min(minReader, state.meta.generation))
      }
      guard let (meta, reclaimLimit) = snapshot else {
        for item in batch { item.fail(.databaseClosed) }
        continue
      }

      let ctx = TxnContext(source: pager, meta: meta)
      do throws(DBError) {
        try FreeList.harvest(ctx: ctx, upTo: reclaimLimit)
      } catch {
        for item in batch { item.fail(error) }
        continue
      }
      let baselineMain = ctx.meta.mainTree

      var completions: [(DBError?) -> Void] = []
      for item in batch {
        let restore = TxnRestorePoint(ctx: ctx)
        ctx.beginRequestScope()
        if let completion = item.attempt(ctx) {
          completions.append(completion)
        } else {
          ctx.rollbackRequestScope()
          restore.apply(to: ctx)
        }
      }
      // Leave request scoping before free-list serialization.
      ctx.requestEpoch = 0

      if completions.isEmpty { continue }
      // Read-only batch: nothing to persist, nothing to sync.
      if ctx.meta.mainTree == baselineMain && ctx.pendingFree.isEmpty && ctx.dirty.isEmpty {
        for completion in completions { completion(nil) }
        continue
      }

      do throws(DBError) {
        try FreeList.serialize(ctx: ctx)
        guard Int(ctx.allocator.highWater) * Format.pageSize <= options.maxMapSize else {
          throw DBError.mapFull
        }
        let newMeta = try Committer.commit(
          ctx: ctx, channel: channel, durability: options.durability)
        shared.withLock { $0.meta = newMeta }
        for completion in completions { completion(nil) }
      } catch {
        for completion in completions { completion(error) }
      }
    }
  }
}

/// Cheap rollback point for one stacked micro-transaction.
struct TxnRestorePoint {
  let meta: Meta
  let pendingFree: [UInt64]
  let pool: [UInt64]
  let highWater: UInt64

  init(ctx: TxnContext) {
    self.meta = ctx.meta
    self.pendingFree = ctx.pendingFree
    self.pool = ctx.allocator.pool
    self.highWater = ctx.allocator.highWater
  }

  /// Restores scalar state; page buffers are restored by
  /// `TxnContext.rollbackRequestScope()`.
  func apply(to ctx: TxnContext) {
    ctx.meta = meta
    ctx.pendingFree = pendingFree
    ctx.allocator.pool = pool
    ctx.allocator.highWater = highWater
  }
}

import Dispatch
import Synchronization

public struct DatabaseOptions: Sendable {
  public var durability: DurabilityProfile
  /// Reserved virtual address space; the file may grow up to this size.
  public var maxMapSize: Int
  public var readOnly: Bool
  public var createIfMissing: Bool

  public init(
    durability: DurabilityProfile = .barrier,
    maxMapSize: Int = 64 << 30,
    readOnly: Bool = false,
    createIfMissing: Bool = true
  ) {
    self.durability = durability
    self.maxMapSize = maxMapSize
    self.readOnly = readOnly
    self.createIfMissing = createIfMissing
  }
}

/// An ADSQL database handle.
///
/// Concurrency model: any number of concurrent readers (snapshot isolation,
/// no locks held while reading pages) and one writer at a time. Reader
/// registration and meta publication share one critical section, so the
/// writer's page-reclamation horizon can never race past a reader that is
/// still acquiring its snapshot.
public final class Database: Sendable {
  struct Shared {
    var meta: Meta
    var closed = false
    /// generation → active read transaction count.
    var readers: [UInt64: Int] = [:]
  }

  public let path: String
  let channel: FileChannel
  let pager: Pager
  let options: DatabaseOptions
  let shared: Mutex<Shared>
  /// Writer exclusion: one serial queue shared by `writeSync` and the
  /// group-commit drain.
  let writeQueue = DispatchQueue(label: "adsql.writer", qos: .userInitiated)
  /// Queued group-commit requests awaiting the next drain.
  let pendingWrites = Mutex<[PendingWrite]>([])

  private init(
    path: String, channel: FileChannel, pager: Pager, options: DatabaseOptions, meta: Meta
  ) {
    self.path = path
    self.channel = channel
    self.pager = pager
    self.options = options
    self.shared = Mutex(Shared(meta: meta))
  }

  public static func open(
    at path: String, options: DatabaseOptions = DatabaseOptions()
  ) throws(DBError) -> Database {
    let channel = try FileChannel(
      path: path,
      mode: options.readOnly ? .readOnly : .readWrite(create: options.createIfMissing))
    let meta: Meta
    do {
      meta = try Recovery.openOrCreate(
        channel: channel, createIfMissing: options.createIfMissing && !options.readOnly)
    } catch {
      channel.close()
      throw error
    }
    guard Int(meta.pageCount) * Format.pageSize <= options.maxMapSize else {
      channel.close()
      throw DBError.mapFull
    }
    let pager: Pager
    do {
      pager = try Pager(channel: channel, maxMapSize: options.maxMapSize)
    } catch {
      channel.close()
      throw error
    }
    return Database(path: path, channel: channel, pager: pager, options: options, meta: meta)
  }

  /// Marks the handle closed; new transactions fail. The mapping and file
  /// descriptor are released when the last reference goes away.
  public func close() {
    shared.withLock { $0.closed = true }
  }

  /// Generation of the most recent commit.
  public var generation: UInt64 {
    shared.withLock { $0.meta.generation }
  }

  /// Number of key-value pairs at the most recent commit.
  public var count: UInt64 {
    shared.withLock { $0.meta.kvCount }
  }

  // MARK: - Reads

  /// Runs `body` against an immutable snapshot of the newest committed
  /// generation. Readers never block the writer and vice versa.
  public func read<R>(
    _ body: (borrowing ReadTxn) throws(DBError) -> R
  ) throws(DBError) -> R {
    let meta = try beginRead()
    defer { endRead(generation: meta.generation) }
    let txn = ReadTxn(resolver: CommittedResolver(source: pager), meta: meta)
    return try body(txn)
  }

  func beginRead() throws(DBError) -> Meta {
    let meta: Meta? = shared.withLock { state in
      guard !state.closed else { return nil }
      state.readers[state.meta.generation, default: 0] += 1
      return state.meta
    }
    guard let meta else { throw DBError.databaseClosed }
    return meta
  }

  func endRead(generation: UInt64) {
    shared.withLock { state in
      if let count = state.readers[generation] {
        if count <= 1 {
          state.readers.removeValue(forKey: generation)
        } else {
          state.readers[generation] = count - 1
        }
      }
    }
  }

  // MARK: - Writes

  /// Runs one exclusive write transaction synchronously. On a thrown error
  /// nothing is persisted; on return the transaction is durably committed
  /// per the database's durability profile.
  @discardableResult
  public func writeSync<R>(
    _ body: (borrowing WriteTxn) throws(DBError) -> R
  ) throws(DBError) -> R {
    guard !options.readOnly else { throw DBError.readOnlyDatabase }
    var result: Result<R, DBError>?
    writeQueue.sync {
      do throws(DBError) {
        result = .success(try performWrite(body))
      } catch {
        result = .failure(error)
      }
    }
    return try result!.get()
  }

  private func performWrite<R>(
    _ body: (borrowing WriteTxn) throws(DBError) -> R
  ) throws(DBError) -> R {
    let snapshot: (Meta, UInt64)? = shared.withLock { state in
      guard !state.closed else { return nil }
      let minReader = state.readers.keys.min() ?? state.meta.generation
      return (state.meta, min(minReader, state.meta.generation))
    }
    guard let (meta, reclaimLimit) = snapshot else { throw DBError.databaseClosed }

    let ctx = TxnContext(source: pager, meta: meta)
    try FreeList.harvest(ctx: ctx, upTo: reclaimLimit)
    let baselineMain = ctx.meta.mainTree

    let txn = WriteTxn(ctx: ctx)
    let result = try body(txn)

    // Nothing user-visible changed: drop the transaction entirely (harvest
    // churn was memory-only).
    if ctx.meta.mainTree == baselineMain && ctx.pendingFree.isEmpty && ctx.dirty.isEmpty {
      return result
    }

    try FreeList.serialize(ctx: ctx)
    guard Int(ctx.allocator.highWater) * Format.pageSize <= options.maxMapSize else {
      throw DBError.mapFull
    }
    let newMeta = try Committer.commit(
      ctx: ctx, channel: channel, durability: options.durability)
    shared.withLock { $0.meta = newMeta }
    return result
  }
}

// MARK: - Transactions

/// A read snapshot. Noncopyable and only ever borrowed by the `read` closure,
/// so it cannot outlive its reader registration.
public struct ReadTxn: ~Copyable {
  let resolver: CommittedResolver
  let meta: Meta

  public var generation: UInt64 { meta.generation }
  public var count: UInt64 { meta.kvCount }

  /// Copying point lookup.
  public func get(_ key: [UInt8]) throws(DBError) -> [UInt8]? {
    var result: Result<[UInt8]?, DBError> = .success(nil)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        guard let ref = try BTree.get(resolver: resolver, meta: meta, key: keyBytes) else {
          return
        }
        result = .success(try BTree.copyValue(ref, resolver: resolver))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  public func contains(_ key: [UInt8]) throws(DBError) -> Bool {
    var result: Result<Bool, DBError> = .success(false)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        result = .success(try BTree.get(resolver: resolver, meta: meta, key: keyBytes) != nil)
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  /// Zero-copy scoped access: inline values are handed out as a `RawSpan`
  /// over the mapped page (bounds-checked, non-escapable); overflow values
  /// are materialized once and spanned. `body` receives nil when the key is
  /// absent.
  public func withValue<R>(
    forKey key: [UInt8], _ body: (RawSpan?) throws(DBError) -> R
  ) throws(DBError) -> R {
    var result: Result<R, DBError>?
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        guard let ref = try BTree.get(resolver: resolver, meta: meta, key: keyBytes) else {
          result = .success(try body(nil))
          return
        }
        switch ref {
        case .inline(let bytes):
          result = .success(try body(RawSpan(_unsafeBytes: bytes)))
        case .overflow:
          let copied = try BTree.copyValue(ref, resolver: resolver)
          var inner: Result<R, DBError>?
          copied.withUnsafeBytes { raw in
            do throws(DBError) {
              inner = .success(try body(RawSpan(_unsafeBytes: raw)))
            } catch {
              inner = .failure(error)
            }
          }
          result = inner
        }
      } catch {
        result = .failure(error)
      }
    }
    return try result!.get()
  }

  /// Scoped ordered iteration over the snapshot.
  public func withCursor<R>(
    _ body: (inout Cursor<CommittedResolver>) throws(DBError) -> R
  ) throws(DBError) -> R {
    var cursor = Cursor(resolver: resolver, meta: meta)
    return try body(&cursor)
  }

  /// Visits every (key, value) pair in order. Values are materialized.
  public func forEach(
    _ body: ([UInt8], [UInt8]) throws(DBError) -> Void
  ) throws(DBError) {
    try BTree.forEach(resolver: resolver, meta: meta) { (key, ref) throws(DBError) in
      try body([UInt8](key), try BTree.copyValue(ref, resolver: resolver))
    }
  }
}

/// An exclusive write transaction. Mutations become visible atomically at
/// commit (when the `writeSync` closure returns without throwing).
public struct WriteTxn: ~Copyable {
  let ctx: TxnContext

  /// Inserts or replaces.
  public func put(_ key: [UInt8], _ value: [UInt8]) throws(DBError) {
    var failure: DBError?
    key.withUnsafeBytes { keyBytes in
      value.withUnsafeBytes { valueBytes in
        do throws(DBError) {
          try BTree.put(ctx: ctx, key: keyBytes, value: valueBytes)
        } catch {
          failure = error
        }
      }
    }
    if let failure { throw failure }
  }

  /// Returns true when the key existed.
  @discardableResult
  public func delete(_ key: [UInt8]) throws(DBError) -> Bool {
    var result: Result<Bool, DBError> = .success(false)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        result = .success(try BTree.delete(ctx: ctx, key: keyBytes))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  /// Reads through this transaction's own uncommitted writes.
  public func get(_ key: [UInt8]) throws(DBError) -> [UInt8]? {
    var result: Result<[UInt8]?, DBError> = .success(nil)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        guard let ref = try BTree.get(resolver: ctx, meta: ctx.meta, key: keyBytes) else {
          return
        }
        result = .success(try BTree.copyValue(ref, resolver: ctx))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  public var count: UInt64 { ctx.meta.kvCount }
}

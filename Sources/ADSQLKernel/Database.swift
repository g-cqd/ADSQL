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
    /// Last minimum published to the cross-process slot (0 = none).
    var publishedMin: UInt64 = 0
  }

  public let path: String
  let channel: FileChannel
  let pager: Pager
  let options: DatabaseOptions
  let readerTable: ReaderTable
  let shared: Mutex<Shared>
  /// Writer exclusion: one serial queue shared by `writeSync` and the
  /// group-commit drain.
  let writeQueue = DispatchQueue(label: "adsql.writer", qos: .userInitiated)
  /// Queued group-commit requests awaiting the next drain.
  let pendingWrites = Mutex<[PendingWrite]>([])
  /// Latest-known schema snapshot, keyed by catalog version (MVCC-correct:
  /// readers verify their snapshot's version row before reuse).
  let relationSchemaCache = SchemaCache()
  /// Parsed-statement LRU keyed by SQL text (the schema-independent half of
  /// `prepare`). Bound plans live on each `Statement`, keyed by catalog
  /// version.
  let statementCache = Mutex<StatementCache>(StatementCache(capacity: 128))

  private init(
    path: String, channel: FileChannel, pager: Pager, options: DatabaseOptions,
    readerTable: ReaderTable, meta: Meta
  ) {
    self.path = path
    self.channel = channel
    self.pager = pager
    self.options = options
    self.readerTable = readerTable
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
    // Cross-process coordination: reader slot for every handle, the fcntl
    // writer lock for read-write handles.
    let readerTable: ReaderTable
    do {
      readerTable = try ReaderTable(databasePath: path, claimWriterLock: !options.readOnly)
    } catch {
      channel.close()
      throw error
    }
    return Database(
      path: path, channel: channel, pager: pager, options: options,
      readerTable: readerTable, meta: meta)
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

  @inline(__always)
  static func checkUserKey(_ key: [UInt8]) throws(DBError) {
    if key.first == Format.reservedKeyPrefix { throw DBError.reservedKey }
  }

  // MARK: - Reads

  /// Runs `body` against an immutable snapshot of the newest committed
  /// generation. Readers never block the writer and vice versa.
  public func read<R>(
    _ body: (borrowing ReadTxn) throws(DBError) -> R
  ) throws(DBError) -> R {
    let meta = try beginRead()
    defer { endRead(generation: meta.generation) }
    let txn = ReadTxn(
      resolver: CommittedResolver(source: pager), meta: meta,
      schemaCache: relationSchemaCache)
    return try body(txn)
  }

  func beginRead() throws(DBError) -> Meta {
    // Read-only handles have no writer in-process: refresh the committed
    // meta from the mapped meta pages (checksums make torn reads safe).
    let refreshed: Meta? =
      if options.readOnly {
        unsafe try? Meta.recover(meta0: pager.map.pageBytes(0), meta1: pager.map.pageBytes(1))
      } else {
        nil
      }
    let meta: Meta? = shared.withLock { state in
      guard !state.closed else { return nil }
      if let refreshed, refreshed.generation > state.meta.generation {
        state.meta = refreshed
      }
      state.readers[state.meta.generation, default: 0] += 1
      publishMinLocked(&state)
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
      publishMinLocked(&state)
    }
  }

  /// Mirrors the in-process minimum reader generation into this handle's
  /// cross-process slot. Called with the state lock held, so slot order is
  /// consistent with meta publication.
  private func publishMinLocked(_ state: inout Shared) {
    let minimum = state.readers.keys.min() ?? 0
    if minimum != state.publishedMin {
      readerTable.publish(minGeneration: minimum)
      state.publishedMin = minimum
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
    readerTable.sweepStaleSlots()
    let foreignMin = readerTable.minimumGeneration() ?? UInt64.max
    let snapshot: (Meta, UInt64)? = shared.withLock { state in
      guard !state.closed else { return nil }
      let localMin = state.readers.keys.min() ?? UInt64.max
      return (state.meta, state.meta.reclaimLimit(minReader: min(localMin, foreignMin)))
    }
    guard let (meta, reclaimLimit) = snapshot else { throw DBError.databaseClosed }

    let ctx = TxnContext(source: pager, meta: meta)
    try FreeList.harvest(ctx: ctx, upTo: reclaimLimit)
    let baselineMain = ctx.meta.mainTree

    let txn = WriteTxn(ctx: ctx)
    let result = try body(txn)
    if ctx.relation != nil {
      try Relation.serializeState(ctx: ctx)
    }

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
    if let state = ctx.relation { relationSchemaCache.publish(state.schema) }
    return result
  }
}

// MARK: - Transactions

/// A read snapshot. Noncopyable and only ever borrowed by the `read` closure,
/// so it cannot outlive its reader registration.
public struct ReadTxn: ~Copyable {
  let resolver: CommittedResolver
  let meta: Meta
  let schemaCache: SchemaCache?

  public var generation: UInt64 { meta.generation }
  public var count: UInt64 { meta.kvCount }

  /// Copying point lookup.
  public func get(_ key: [UInt8]) throws(DBError) -> [UInt8]? {
    try Database.checkUserKey(key)
    var result: Result<[UInt8]?, DBError> = .success(nil)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        guard let ref = unsafe try BTree.get(resolver: resolver, meta: meta, key: keyBytes) else {
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
    try Database.checkUserKey(key)
    var result: Result<Bool, DBError> = .success(false)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        result = unsafe .success(try BTree.get(resolver: resolver, meta: meta, key: keyBytes) != nil)
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
    try Database.checkUserKey(key)
    var result: Result<R, DBError>?
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        guard let ref = unsafe try BTree.get(resolver: resolver, meta: meta, key: keyBytes) else {
          result = .success(try body(nil))
          return
        }
        switch ref {
        case .inline(let bytes):
          // bytes is a borrowed view of the mapped page, alive for this scope.
          result = unsafe .success(
            try Self.withRawSpan(over: bytes) { (span: RawSpan) throws(DBError) in try body(span) })
        case .overflow:
          let copied = try BTree.copyValue(ref, resolver: resolver)
          var inner: Result<R, DBError>?
          copied.withUnsafeBytes { raw in
            do throws(DBError) {
              // raw is owned by `copied`, alive for this withUnsafeBytes scope.
              inner = unsafe .success(
                try Self.withRawSpan(over: raw) { (span: RawSpan) throws(DBError) in try body(span) })
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

  /// The single bridge from raw bytes to the safe `RawSpan` type. The
  /// underscored `_unsafeBytes:` SPI asserts (does not check) the span's
  /// lifetime and is unstable across compilers, so it is confined here to one
  /// call site; both callers keep `bytes` alive for the closure's duration
  /// (Review 0001 F5).
  private static func withRawSpan<R, E: Error>(
    over bytes: UnsafeRawBufferPointer, _ body: (RawSpan) throws(E) -> R
  ) throws(E) -> R {
    try body(unsafe RawSpan(_unsafeBytes: bytes))
  }

  /// Scoped ordered iteration over the snapshot.
  public func withCursor<R>(
    _ body: (inout Cursor<CommittedResolver>) throws(DBError) -> R
  ) throws(DBError) -> R {
    var cursor = Cursor(resolver: resolver, meta: meta)
    return try body(&cursor)
  }

  /// Visits every user (key, value) pair in order (system rows under the
  /// reserved 0x00 prefix are skipped). Values are materialized.
  public func forEach(
    _ body: ([UInt8], [UInt8]) throws(DBError) -> Void
  ) throws(DBError) {
    unsafe try BTree.forEach(resolver: resolver, meta: meta) { (key, ref) throws(DBError) in
      if unsafe key.first == Format.reservedKeyPrefix { return }
      unsafe try body([UInt8](key), try BTree.copyValue(ref, resolver: resolver))
    }
  }
}

/// An exclusive write transaction. Mutations become visible atomically at
/// commit (when the `writeSync` closure returns without throwing).
public struct WriteTxn: ~Copyable {
  let ctx: TxnContext

  /// Inserts or replaces.
  public func put(_ key: [UInt8], _ value: [UInt8]) throws(DBError) {
    try Database.checkUserKey(key)
    var failure: DBError?
    key.withUnsafeBytes { keyBytes in
      value.withUnsafeBytes { valueBytes in
        do throws(DBError) {
          unsafe try BTree.put(ctx: ctx, key: keyBytes, value: valueBytes)
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
    try Database.checkUserKey(key)
    var result: Result<Bool, DBError> = .success(false)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        result = unsafe .success(try BTree.delete(ctx: ctx, key: keyBytes))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  /// Reads through this transaction's own uncommitted writes.
  public func get(_ key: [UInt8]) throws(DBError) -> [UInt8]? {
    try Database.checkUserKey(key)
    var result: Result<[UInt8]?, DBError> = .success(nil)
    key.withUnsafeBytes { keyBytes in
      do throws(DBError) {
        guard let ref = unsafe try BTree.get(resolver: ctx, meta: ctx.meta, key: keyBytes) else {
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

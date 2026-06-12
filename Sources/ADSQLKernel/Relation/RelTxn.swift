import Synchronization

/// Latest-schema cache shared by readers. MVCC-correct: a transaction reads
/// its snapshot's version row first and only reuses the cache on a match,
/// so old-generation readers reconstruct their own (older) schema instead
/// of seeing a newer one.
public final class SchemaCache: Sendable {
  private let cached = Mutex<Schema?>(nil)

  public init() {}

  func schema(resolver: some PageResolver, meta: Meta) throws(DBError) -> Schema {
    let version = try currentVersion(resolver: resolver, meta: meta)
    if let snapshot = cached.withLock({ $0 }), snapshot.catalogVersion == version {
      return snapshot
    }
    let loaded = try Relation.loadState(resolver: resolver, mainTree: meta.mainTree).schema
    cached.withLock { existing in
      if existing == nil || existing!.catalogVersion <= loaded.catalogVersion {
        existing = loaded
      }
    }
    return loaded
  }

  /// Writer-side publish after a DDL commit (already authoritative).
  func publish(_ schema: Schema) {
    cached.withLock { existing in
      if existing == nil || existing!.catalogVersion <= schema.catalogVersion {
        existing = schema
      }
    }
  }

  private func currentVersion(
    resolver: some PageResolver, meta: Meta
  ) throws(DBError) -> UInt64 {
    guard let bytes = try Relation.getBytes(resolver, meta.mainTree, key: Catalog.versionKey)
    else { return 0 }
    var result: Result<UInt64, DBError> = .success(0)
    bytes.withUnsafeBytes { raw in
      do throws(DBError) {
        result = .success(try Catalog.decodeVersion(raw).catalogVersion)
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }
}

// MARK: - Public relational API

extension ReadTxn {
  /// The schema as of this snapshot.
  public func schema() throws(DBError) -> Schema {
    if let schemaCache {
      return try schemaCache.schema(resolver: resolver, meta: meta)
    }
    return try Relation.loadState(resolver: resolver, mainTree: meta.mainTree).schema
  }
}

extension WriteTxn {
  /// The schema as seen by this transaction (including its own DDL).
  public func schema() throws(DBError) -> Schema {
    try Relation.ensureState(ctx).schema
  }

  /// Creates a table. Transactional and crash-atomic like any other write.
  public func createTable(_ definition: TableDefinition) throws(DBError) {
    try Relation.createTable(ctx, definition)
  }

  /// Drops a table, its indexes, and every page they own.
  public func dropTable(_ name: String) throws(DBError) {
    try Relation.dropTable(ctx, name: name)
  }

  /// Creates an index (backfilling from existing rows).
  public func createIndex(_ definition: IndexDefinition) throws(DBError) {
    try Relation.createIndex(ctx, definition)
  }

  public func dropIndex(_ name: String) throws(DBError) {
    try Relation.dropIndex(ctx, name: name)
  }
}

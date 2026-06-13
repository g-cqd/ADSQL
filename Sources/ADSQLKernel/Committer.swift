/// The commit protocol. Committed pages are immutable, so the only ordering
/// that matters is "all data pages before the meta flip":
///
///   1. preallocate the file to the new high-water mark
///   2. stamp checksums on every dirty page
///   3. write dirty pages (sorted, contiguous runs gathered into pwritev)
///   4. sync (barrier or full, per durability profile)
///   5. write the new meta to page (generation % 2)
///   6. `.full` only: sync again (commit durable on return)
///
/// Recovery is `Meta.recover` over the two meta pages: the newest
/// checksum-valid one wins; a torn in-flight meta falls back one generation.
/// With `.barrier`, ordering (not durability) is guaranteed: a power cut
/// recovers *some* committed generation, at least the last fully-synced one.
public enum Committer {
  /// Applies `ctx` to storage. Returns the committed meta (generation + 1),
  /// or the unchanged base meta for a no-op transaction.
  public static func commit(
    ctx: TxnContext, channel: any StorageChannel, durability: DurabilityProfile
  ) throws(DBError) -> Meta {
    var newMeta = ctx.meta
    newMeta.pageCount = ctx.allocator.highWater

    if ctx.dirty.isEmpty && newMeta == ctx.meta {
      return ctx.meta
    }

    newMeta.generation = ctx.meta.generation + 1
    try channel.preallocate(minimumSize: Int(newMeta.pageCount) * Format.pageSize)

    // Stamp and gather. Sorting by page number gives the disk a mostly
    // sequential pass; contiguous runs become single vectored writes.
    let pageNos = ctx.dirty.keys.sorted()
    var index = 0
    while index < pageNos.count {
      var run: [UnsafeRawBufferPointer] = unsafe []
      let startPage = pageNos[index]
      var nextExpected = startPage
      while index < pageNos.count, pageNos[index] == nextExpected {
        let buf = ctx.dirty[pageNos[index]]!
        unsafe PageHeader.stampChecksum(buf.raw, pageNo: pageNos[index])
        unsafe run.append(buf.readOnly)
        nextExpected += 1
        index += 1
      }
      unsafe try channel.pwritev(run, at: Int(startPage) * Format.pageSize)
    }

    // The pre-meta sync only needs ORDERING (data before meta) — even for
    // `.full`, whose trailing F_FULLFSYNC flushes the whole device cache
    // including these pages. One full flush per commit, not two.
    try channel.sync(durability == .full ? .barrier : durability)

    let metaBuf = PageBuf()
    let metaPageNo = newMeta.pageNo
    unsafe newMeta.encode(into: metaBuf.raw, pageNo: metaPageNo)
    unsafe try channel.pwrite(metaBuf.readOnly, at: Int(metaPageNo) * Format.pageSize)

    // `.full` must make THIS commit power-loss durable before returning.
    // `.barrier` needs no trailing barrier: the next commit's barrier
    // orders this meta ahead of the next meta, and page reuse lags one
    // generation (Meta.reclaimLimit), so recovery to N-1 is always sound.
    if durability == .full {
      try channel.sync(.full)
    }
    return newMeta
  }
}

/// Opening and creating database files.
public enum Recovery {
  /// Opens an existing database (recovering the newest valid meta) or
  /// initializes a fresh one.
  public static func openOrCreate(
    channel: any StorageChannel, createIfMissing: Bool = true
  ) throws(DBError) -> Meta {
    let size = try channel.fileSize()
    if size == 0 {
      guard createIfMissing else { throw DBError.badMagic }
      return try create(channel: channel)
    }
    guard size >= Int(Format.metaPageCount) * Format.pageSize else {
      throw DBError.badMagic
    }
    let meta0 = try channel.preadBytes(count: Format.pageSize, at: 0)
    let meta1 = try channel.preadBytes(count: Format.pageSize, at: Format.pageSize)
    var recovered: Result<Meta, DBError> = .failure(.bothMetasInvalid)
    meta0.withUnsafeBytes { m0 in
      meta1.withUnsafeBytes { m1 in
        do throws(DBError) {
          recovered = unsafe .success(try Meta.recover(meta0: m0, meta1: m1))
        } catch {
          recovered = .failure(error)
        }
      }
    }
    return try recovered.get()
  }

  static func create(channel: any StorageChannel) throws(DBError) -> Meta {
    let meta = Meta.empty
    try channel.preallocate(minimumSize: Int(Format.metaPageCount) * Format.pageSize)
    let buf = PageBuf()
    unsafe meta.encode(into: buf.raw, pageNo: 0)
    unsafe try channel.pwrite(buf.readOnly, at: 0)
    let zero = PageBuf()
    unsafe try channel.pwrite(zero.readOnly, at: Format.pageSize)
    // Creation is durable regardless of profile: one-time cost.
    try channel.sync(.full)
    return meta
  }
}

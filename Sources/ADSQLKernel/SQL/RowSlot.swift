/// On-demand row view over a record's bytes *in place* — the bytes are an
/// `UnsafeRawBufferPointer` into the mapped page (or dirty page buffer), set
/// per row by `load` and valid only for the current scan-body scope. Decodes a
/// column only when the evaluator asks for it and caches the result, so a scan
/// that filters on one column never materializes the rest of a rejected row,
/// and never copies the whole record. The rowid-alias column reads back from
/// the rowid, and columns beyond the stored count fall to their schema default
/// (mirroring `Relation.materializeRow`).
// SAFETY (Review 0001 F1): unlike RowView/ValueRef (now `~Escapable`, lifetime-
// checked), this stays `@safe` over a stored raw pointer because the invariant
// is not compiler-enforceable here. `span` is re-pointed by `load` each row and
// read only within that row's scan body; the slot caches decoded `Value`s, not
// the bytes. Column reads are *decoupled* from the scan body — they arrive
// through the per-row `SQLEvalEnv.column` closure (whose `scalarSubquery` field
// is `@escaping`, which a `~Escapable` `RawSpan` cannot be captured into) — so
// the span must be stored, not threaded as a parameter. Enforcing this would
// require routing a `RawSpan` through the whole evaluator. The slot is query-
// internal (`RowContext.slots`) and never escapes the scan loop; its lifetime
// is bounded by the owning `forEach*` call. Owner: the scan driver. Bounds: one
// scan body. Invariant asserted, not enforced.
@safe final class RowSlot {
  private let columns: [ColumnDefinition]
  private let aliasIndex: Int?
  /// The FTS `rank` score column index (slot 1 of the synthetic FTS definition),
  /// if this slot models an FTS table. `compute` returns the per-row `score` for
  /// it without touching the span, parallel to the `aliasIndex → rowid` path.
  private let scoreIndex: Int?
  private(set) var rowid: Int64 = 0
  /// The bm25 relevance score of the current FTS row (`.real(score)` for the
  /// `rank` column). Zero for non-FTS rows, where `scoreIndex` is nil.
  private var score: Double = 0
  private var span = unsafe UnsafeRawBufferPointer(start: nil, count: 0)
  private var cache: [Value?]
  // Incremental cell location: `offsets[i]` is the byte start of stored cell i,
  // filled lazily up to the highest column read. Reused across rows (storage
  // kept), so a sort-key-only scan pays no per-row [Int] allocation and walks
  // only as far as the columns it touches.
  private var offsets: [Int]
  private var locatedCount = 0     // cells whose start is recorded in `offsets`
  private var scanOffset = 0       // byte offset of the next unlocated cell
  private var storedCount = 0
  private var headerParsed = false

  init(table: TableDefinition) {
    self.columns = table.columns
    self.aliasIndex = table.rowidAliasIndex
    self.scoreIndex = table.ftsScoreIndex
    self.cache = Array(repeating: nil, count: table.columns.count)
    self.offsets = []
    self.offsets.reserveCapacity(table.columns.count)
  }

  /// Re-points the slot at a new row's record span; resets the decode state.
  /// `score` is the FTS row's bm25 score (ignored when not an FTS slot). The
  /// span must stay valid for as long as the slot is read (the scan driver
  /// guarantees this within the per-row body).
  func load(rowid: Int64, span: UnsafeRawBufferPointer, score: Double = 0) {
    self.rowid = rowid
    self.score = score
    unsafe self.span = unsafe span
    self.headerParsed = false
    self.locatedCount = 0
    self.offsets.removeAll(keepingCapacity: true)
    for index in cache.indices { cache[index] = nil }
  }

  /// Loads a fully materialized row (no span). The hash-join build side decodes
  /// its rows once into `[Value]` (via `materialize`) and re-serves them during
  /// the probe; every column is pre-cached so `value(at:)` never reads the (nil)
  /// span. `values` must cover all columns (i.e. come from `materialize`).
  func loadMaterialized(rowid: Int64, values: [Value]) {
    self.rowid = rowid
    self.score = 0
    for index in cache.indices { cache[index] = index < values.count ? values[index] : nil }
  }

  func value(at index: Int) throws(DBError) -> Value {
    if let cached = cache[index] { return cached }
    let value = try compute(at: index)
    cache[index] = value
    return value
  }

  /// Zero-copy access to a stored TEXT (resp. BLOB) column's payload bytes in
  /// place — no `String`/`[UInt8]`. `body` gets nil when the column is NULL, a
  /// different storage class, the rowid-alias/score slot, or not stored by a short
  /// row (the caller then falls back to the `Value` path). Valid only within the
  /// call; the span is the same one `compute` reads, so the usual per-row scope
  /// applies. Used by the join's zero-copy probe-key build.
  func withTextBytes<R>(
    at index: Int, _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    if index == aliasIndex || index == scoreIndex { return try body(nil) }
    return unsafe try RecordCodec.withText(at: index, in: span, body)
  }

  func withBlobBytes<R>(
    at index: Int, _ body: (UnsafeRawBufferPointer?) throws(DBError) -> R
  ) throws(DBError) -> R {
    if index == aliasIndex || index == scoreIndex { return try body(nil) }
    return unsafe try RecordCodec.withBlob(at: index, in: span, body)
  }

  /// All columns as a materialized row — the eager fallback (projection of
  /// `*`, RETURNING) and the property-test oracle against `materializeRow`.
  func materialize() throws(DBError) -> [Value] {
    var values: [Value] = []
    values.reserveCapacity(columns.count)
    for index in columns.indices { values.append(try value(at: index)) }
    return values
  }

  private func compute(at index: Int) throws(DBError) -> Value {
    if index == aliasIndex { return .integer(rowid) }
    // The FTS `rank` slot reads the precomputed score, never the (empty) span.
    if index == scoreIndex { return .real(score) }
    guard let start = try locate(index) else {
      switch columns[index].defaultValue {
      case .value(let value): return value
      case .datetimeNow, nil: return .null
      }
    }
    return unsafe try RecordCodec.decodeCell(span, at: start)
  }

  /// Byte start of stored cell `index`, or nil if beyond the stored count.
  /// Walks (and records) only as far as `index`, reusing prior work.
  private func locate(_ index: Int) throws(DBError) -> Int? {
    if !headerParsed {
      var offset = 0
      storedCount = unsafe try RecordCodec.readHeader(span, &offset)
      scanOffset = offset
      headerParsed = true
    }
    if index >= storedCount { return nil }
    while locatedCount <= index {
      offsets.append(scanOffset)
      unsafe try RecordCodec.skipCell(span, &scanOffset)
      locatedCount += 1
    }
    return offsets[index]
  }
}

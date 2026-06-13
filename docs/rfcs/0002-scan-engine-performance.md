# RFC 0002 — Scan-Engine Performance (M4.6)

Status: implemented. Closes the bulk of the filtered-scan headroom recorded in
`ROADMAP.md` without changing results — correctness is held by the
superset+residual contract (RFC 0001) and the differential suites.

## Result

`sql search` (`SELECT id, key FROM docs WHERE framework=? AND kind=? ORDER BY
key LIMIT 20`, 100k rows) went **14.3 ms → 5.34 ms p50 (2.66×)** vs SQLite's
1.76 ms (now 3.0×, was 8.2×). The three changes contributed roughly:

| Step | search p50 | note |
|---|---|---|
| baseline | 14.3 ms | collect all ~8.3k matches, full-sort, full residual |
| + zero-copy decode | 14.2 ms | record copy was *not* the bottleneck |
| + bounded top-N | 10.4 ms | stop materializing+sorting all matches for LIMIT 20 |
| + residual elimination | **5.34 ms** | stop re-decoding framework/kind per row |

The surprise: the per-row record copy (the original hypothesis) barely moved
the needle. The real costs were materializing every match for an ORDER BY +
LIMIT and re-checking predicates the index already guaranteed. The remaining
3× is the per-row index→table descent (shared with SQLite) and
`cellOffsets` walking/allocating the full offset table to read one sort-key
column — a future incremental single-column decode.

## Problem

ADSQL leads SQLite on point/cold/concurrent reads but trails badly on filtered
scans (100k rows, vs system SQLite):

- `sql search` (`SELECT id, key FROM docs WHERE framework=? AND kind=? ORDER BY key LIMIT 20`):
  **14.3 ms** vs **1.76 ms** — 0.12× (8.2× slower).
- relational index scan: **1.23 M rows/s** vs **3.53 M/s** — 0.35×.

Both engines pay the same per-row index→rowid→table descent, so the gap is
ADSQL's per-row *overhead* on top of it. Root causes (confirmed in code):

1. **Per-row full record copy.** `RowCursor.nextRecord` materializes the whole
   ~580 B record into a fresh `[UInt8]` via `BTree.copyValue` for every scanned
   row — before WHERE runs and regardless of projection (`Rows.swift`). The
   value is already a zero-copy page span (`BTree.ValueRef.inline`), and
   `RecordCodec.cellOffsets/decodeCell` already decode from an
   `UnsafeRawBufferPointer`, so the copy is pure overhead for inline values.
2. **Redundant residual.** After an exact equality probe, the executor
   re-decodes and re-evaluates the same columns as the WHERE residual on every
   row (`Executor.swift`).
3. **Per-row allocations.** `RowSlot` clears a `[Value?]` cache per row;
   projection/sort-key arrays per surviving row.

## Design

### Slice 1 — Zero-copy row decode

Decode each scanned row in place from its mapped page span rather than copying.

- `RowSlot` holds a current-row `UnsafeRawBufferPointer` (set per row) instead
  of an owned `[UInt8]`; `value(at:)`/`materialize()` decode from it via the
  existing span-based `RecordCodec`. The span is valid only within the per-row
  `consume` call and never escapes — projection copies out owned `Value`s.
- Row sources run the body inside the value's valid scope: table scans via
  `Cursor.withCurrent`; index/rowid fetches via a new zero-copy
  `Relation.withRowValue(resolver, tree, key:) { ref in … }` (replacing the
  `getBytes`-copy). `.overflow` values (rare; large) fall back to an owned copy.
- `RowCursor.next()` (full materialize) stays for the relational API; the
  executor stops using the copying `nextRecord` on its hot path.

Safety: the span points into immutable committed pages (COW) for a read
snapshot, valid for the txn; confining its use to `consume` keeps the contract
simple. This is the only new unsafe surface and is documented at the call site.

### Slice 2 — Bounded top-N for ORDER BY + LIMIT

An unordered ORDER BY with a small LIMIT (≤ 4096, no DISTINCT) keeps only
`offset+limit` rows in an ascending bounded buffer instead of materializing and
sorting every match: per row the accumulator computes the sort key first and
projects (decodes output columns) only rows that beat the current worst,
dropping the rest in O(1). Larger bounds fall back to collect-and-sort. This was
the single biggest contributor (10.4 ms of the 14.3→5.34 path).

### Slice 3 — Drop residual conjuncts covered by an exact probe

The planner reports the `col = const` conjuncts a rowid/index probe satisfies
**exactly** (same storage class, no range widening). When the executor actually
uses that probe (not the type-coercion `.scan` fallback), its residual = full
WHERE minus the covered conjuncts; on fallback it keeps the full WHERE.

## Safety argument

No slice can change results:

- Slice 1 changes *where bytes live*, not what is decoded.
- Slice 2 keeps the same top-`offset+limit` rows an ORDER BY + LIMIT would
  select; it only avoids materializing the rest. Bounded only when there is no
  DISTINCT and `limit ≥ 1`.
- Slice 3 only removes a predicate the chosen probe already guarantees, and
  reverts to the full WHERE whenever the probe isn't used. The
  superset+residual contract (RFC 0001) means an over-eager drop would surface
  as a result mismatch in `SQLPlannerResidualTests` (indexed vs unindexed
  ADSQL vs SQLite) — a loud failure.

## Verification

- `swift test` (the differential suites are the correctness gate) +
  `swift test --sanitize=thread`; an added overflow-value scan test exercises
  the non-inline fallback; added search-shaped fuzz cases (exact cover, mixed
  exact+range, coercion fallback).
- `swift run -c release ADSQLBench --rows 100000 sql table`, both engines,
  before/after. Target: close the bulk of the 8.2× search and 0.35× scan gaps
  (approach SQLite; the per-row index→table descent is the shared floor, so
  parity is the ceiling, not the promise).

## Follow-up (M4.7)

The "per-row index→table descent is the shared floor" claim above held only for
an *unordered* fetch. Within one index probe the rowids are ascending, so a warm
table cursor (`Cursor.seekForward`, leaf-local) skips most re-descents — **B7**
in RFC 0003 took `sql search` 5.34 → ~5.0 ms. The relational scan and write-path
items below also landed in M4.7 (A4 lazy `RowView`, B3 `insertAssembled`); see
RFC 0003's outcomes section.

## Out of scope

The join/correlated-subquery index probing is tracked separately in
`ROADMAP.md`. (The write-path `insertAssembled` headroom landed in M4.7/B3 —
the residual insert gap is now the B+tree COW write path, a future item.)

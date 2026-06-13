# RFC 0002 — Scan-Engine Performance (M4.6)

Status: in progress. Closes the filtered-scan headroom recorded in `ROADMAP.md`
without changing results — correctness is held by the superset+residual
contract (RFC 0001) and the existing differential suites.

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

### Slice 2 — Drop residual conjuncts covered by an exact probe

The planner reports the `col = const` conjuncts a rowid/index probe satisfies
**exactly** (same storage class, no range widening). When the executor actually
uses that probe (not the type-coercion `.scan` fallback), its residual = full
WHERE minus the covered conjuncts; on fallback it keeps the full WHERE.

## Safety argument

Neither slice can change results:

- Slice 1 changes *where bytes live*, not what is decoded.
- Slice 2 only removes a predicate the chosen probe already guarantees, and
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

## Out of scope

The write-path `insertAssembled` headroom and join/correlated-subquery index
probing are tracked separately in `ROADMAP.md`.

# RFC 0004 — Performance Optimization Program (M4.8+)

Status: proposed. The actionable, phased plan derived from **Review 0002**
(`docs/reviews/0002-performance-architecture-review.md`), which holds the evidence,
the state-of-the-art synthesis, and the competitor analysis with citations. This RFC is
the *execution* contract: concrete changes, the benchmark each must move, and the risk.
It closes the three measured gaps — filtered scan (a), index→table descent (b), insert
(c) — and the unindexed-join blowup, without abandoning the COW/mmap/single-writer design
(validated by LMDB; see Review 0002 §Verdict).

## Goals

- Recover the filtered-scan and index-scan deficits (gaps a, b) and remove the
  **O(M·N) unindexed join** (the one S1 complexity bug).
- Stay **measurement-first**: every perf item lands only behind an `ADSQLBench` number that
  moves (the RFC 0002 lesson — the obvious hypothesis was wrong by ~100×).
- Change **no results**: the superset+residual contract (RFC 0001) and the differential
  suites vs `CSQLite` remain the gate; TSan stays green.
- Add **no dependencies**; keep the engine architecture.

## Principles (gates)

1. **Profile before optimizing** a constant-factor gap (b); ship an algorithm change (a, c)
   only with before/after on its named scenario.
2. Each item names: *site → change → expected effect → acceptance benchmark → risk*.
3. Phases are ordered by ROI and dependency; P0 profiling gates P1's descent work.

## Phase P0 — measure + cheap asymptotic wins

### P0.1 Profile the index→rowid→table descent  *(safety: none; ROI: high)*
Gap (b) is 0.69× of SQLite; LMDB shows a pure descent is near hardware-limited, so the gap
is almost certainly **constant factor**, not algorithm. Instrument the single rowid-seek
path (`Cursor.seek`/`withCurrent`, `BTree.get`, `TxnContext.resolvePage`) and attribute the
cost: ARC retain/release traffic on `resolver`/page handles, interior-node re-decode per
seek, re-walking from the root vs. reusing the page stack, bounds-check overhead.
- **Acceptance:** a profile (Instruments / `-c release` counters) that names the dominant
  cost; no code change yet. Decides which of P1.2's levers to pull.
- **Risk:** none (measurement only).

### P0.2 `SELECT DISTINCT`: O(n²·m) → O(n)  *(ROI: high; effort: trivial)*
`Executor.deduplicate:799-820` does `keptRows.contains { … }` — a linear scan of kept rows
per row. UNION/GROUP BY already dedup in O(n) via `GroupKey` (`Grouping.swift`). Replace the
quadratic scan with a `Set<GroupKey>` first-occurrence filter (the code's own comment
prescribes this).
- **Acceptance:** add a `sql distinct` bench scenario (≥50k-row result with duplicates);
  expect a large asymptotic drop. Differential `SELECT DISTINCT` tests unchanged.
- **Risk:** low — `GroupKey` canonicalization (numeric unification, NOCASE fold) must match
  the current `orderCompare`-based equality exactly (it already powers UNION).

### P0.3 Index-nested-loop join  *(ROI: high; effort: med)*  — the S1 fix
`Executor.forEachFilteredRow:391` hardcodes `forEachRow(.table, …)` for every inner table,
so a k-way join is O(n₁·…·nₖ) even when an index covers the join key. When the `join.on`
equality references an indexed column of `tables[depth]`, resolve an **index access path**
(reuse `Planner` sargable-conjunct extraction + `resolveSource`) and probe it per outer row
instead of scanning. O(M·N) → O(M·log N). Falls back to `.table` when no index applies.
- **Acceptance:** new `sql join` scenario (indexed FK join, ~100k × ~100k); expect orders-of-
  magnitude improvement vs the scan baseline, and parity-ish with SQLite. All join
  differential tests (`SQLJoinTests`) green.
- **Risk:** med — must preserve LEFT null-extension and the ON-vs-WHERE split; held by the
  differential suite (planner-invariance: indexed vs unindexed must agree).

## Phase P1 — scan / descent (gaps a, b)

### P1.1 Covering indexes (serve from the index cursor)  *(ROI: high; effort: med)*
When every column a query references (SELECT list + WHERE + ORDER BY) is present in a
chosen index, read values off the **index cursor** and never descend to the table — SQLite's
covering-index / Postgres index-only-scan win ("two binary searches" → one). Detect coverage
in the planner; add an `INCLUDE`-style non-key payload to index definitions (on-disk format
addition — coordinate with M5).
- **Acceptance:** `sql search` (gap a) and the relational index scan (gap b) — expect the
  descent to disappear for covered queries (target ≥ parity with SQLite covered scans).
- **Risk:** med — on-disk format change; gate behind format-version; differential tests.

### P1.2 Ordered/batched rowid sweep + prefetch  *(ROI: high; effort: med)*  — for non-covered (b)
For a non-covered index scan, stop interleaving `index-entry → random table seek`. Buffer the
qualifying rowids, **sort** them, then sweep the table cursor forward in rowid order
(Postgres bitmap-heap-scan idea), reusing the cursor page-stack across consecutive seeks
(`seekForward` already exists, M4.7/B7) so sequential rowids reuse the positioned leaf; issue
`madvise(MADV_WILLNEED)` on the next leaf to overlap page-fault latency (pB+-tree prefetch).
Apply the P0.1 profile findings here.
- **Acceptance:** relational index scan rows/s (gap b) before/after; target ≥ 1.0× SQLite.
- **Risk:** low-med — ordering must not change result order semantics (only the *fetch*
  order; final ORDER BY unchanged).

### P1.3 Per-page zone maps (min/max)  *(ROI: med-high; effort: med)*  — for (a)
Maintain per-leaf-page (or per-page-range) min/max for key/filter columns; during a filtered
scan, skip a leaf page whose min/max cannot satisfy the predicate — which, crucially, avoids
that page's **mmap page fault** (the dominant scan cost). Effectiveness scales with clustering
on the filter column.
- **Acceptance:** `sql search` with a selective range predicate on a clustered column; expect
  pages-faulted ↓ and p50 ↓. Neutral when data is unclustered (don't regress).
- **Risk:** med — synopsis maintenance on the write path (keep it cheap; recompute on page
  rewrite only); format addition (gate by version).

## Phase P2 — joins, planner, scan loop (gaps a, c)

### P2.1 In-memory hash join  *(ROI: high for analytical joins; effort: med-high)*
Add a build/probe equi-join operator: build a `[JoinKey: [row]]` table on the smaller input,
stream the larger through it (O(N·M) → ~O(N+M)). Planner-gated by a build-side size estimate
(needs P2.2); fall back to nested-loop / index-nested-loop (P0.3) when the build side is large
or no equi-predicate exists. Account load factor on **distinct** keys. Disk batching deferred.
- **Acceptance:** `sql join` on **unindexed** equi-join columns; expect the largest win here.
- **Risk:** med-high — memory budget + correctness (multi-match, NULLs, LEFT). Differential.

### P2.2 Lightweight `ANALYZE` / statistics  *(ROI: med; effort: med)*  — enabler
Replace the heuristic `score = prefixLen*4 + …` (`Planner.swift:172`) with a small cost model
fed by per-index selectivity (rows-per-distinct-leftmost-value) and table row counts, stored
in a stats table refreshed by `ANALYZE`. Lets the planner choose scan-vs-seek, the right
index, and hash-vs-(index-)nested-loop on cardinality (SQLite NGQP + `sqlite_stat`).
- **Acceptance:** planner picks the better path on mixed-selectivity fixtures; `SQLPlannerTests`
  extended. No result change.
- **Risk:** med — a bad cost model picks worse plans; keep conservative, keep residual safety.

### P2.3 Batch-at-a-time filter evaluation  *(ROI: med; effort: med; behind a benchmark)*
Transpose a batch (~1–2k rows) of decoded values into transient per-column buffers and run the
WHERE predicate over the batch, amortizing per-row interpreter dispatch (the fitting slice of
vectorization for a row store). Pairs with a flatter, monomorphic scan loop (SQLite VDBE
spirit) on the hottest path.
- **Acceptance:** `sql search` p50; ship only if it moves (per RFC 0002 discipline).
- **Risk:** med — added complexity; must not regress small queries (gate by row-count threshold).

### P2.4 Correlated subquery: index-probe / decorrelate  *(ROI: med; effort: med)*
The correlated scalar subquery re-scans the inner relation per outer row. Push the correlated
equality into an index probe on the inner table (reuse P0.3), or decorrelate to a join where
shape allows.
- **Acceptance:** a correlated-subquery bench; expect O(N·M) → O(N·logM). `SQLSubqueryTests` green.
- **Risk:** med — semantics of NULL/empty must match (returns NULL when empty).

### P2.5 Drop write-path `Array(s.utf8)` copies  *(ROI: low; effort: trivial)*
`RecordCodec.encode:37` and `KeyCodec.append:52,55` allocate a throwaway array per text cell;
append `s.utf8` directly.
- **Acceptance:** `sql insert` / bulk-load allocation count ↓; neutral-to-slightly-positive p50.
- **Risk:** low.

## Phase P3 — long-term / out of scope (documented, not scheduled)

- **Spillable external merge sort** (in-memory quicksort + run files + k-way merge) to remove
  the 4096 top-N cliff and the OOM risk on huge ORDER BY, and to unblock a future sort-merge
  join. *(effort: high.)*
- **Morsel-parallel scans** over a thread pool (multi-reader MVCC makes this natural). *(high.)*
- **Reduce COW write-path page copies** (gap c): larger group-commit batches; avoid the
  group-commit double-clone (`TxnContext.shadow:103-108`) where a request won't roll back.
  Gap (c) is an *inherent* COW trade (LMDB pays it too) — treat as constant-factor tuning.
- **No-fit (rationale in Review 0002):** full vectorized/columnar engine, JIT-compiled plans,
  radix-partitioned joins, Bw-tree, in-place+undo MVCC, LSM.
- **mmap residual risks** (Crotty/Leis/Pavlo, CIDR 2022): install a `SIGBUS` handler for
  storage faults; accept/disclose synchronous page-fault stalls for larger-than-RAM DBs;
  steer the kernel with `madvise`. Document as known limitations.
- **FTS5 (M5)** is the next milestone and needs its own design note (postings layout, tokenizer
  cost, position lists, `bm25`); explicitly out of scope here.

## Sequencing & dependencies

```
P0.1 profile ─┐
P0.2 DISTINCT │ (independent, do immediately)
P0.3 INLJ ────┴─→ P2.1 hash join ── needs ── P2.2 stats/cost model
P1.1 covering ─┐
P1.2 rowid sweep (uses P0.1) ─┼─→ gap (b)
P1.3 zone maps ┘                 gap (a)
P2.3 batch filter ── gap (a), independent, benchmark-gated
```

## Verification (acceptance method)

- **KPIs (both engines, `-c release`, ≥100k rows, before/after):**
  `ADSQLBench sql search` (gap a), the relational index-scan rows/s (gap b), `sql insert`
  (gap c), plus **new** `sql join`, `sql distinct`, and correlated-subquery scenarios. Report
  median + spread; a perf item that doesn't move its scenario is not landed as a perf win.
- **Correctness gate (unchanged):** `swift test` (differential vs `CSQLite`, including
  planner-invariance: indexed vs unindexed vs SQLite must agree) + `swift test
  --sanitize=thread --skip-tag soak` green for every change.
- **Format changes** (P1.1 covering payload, P1.3 zone maps) gate behind a format version and
  ship with crash-injection coverage (M6 harness).

## Out of scope

Memory-safety / `@safe`/Span posture (covered by RFC 0003 + Review 0001); FTS5/vector (M5);
the importer (M6).

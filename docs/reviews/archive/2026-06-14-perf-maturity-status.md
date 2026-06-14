<!--
  ARCHIVED VERBATIM (Deliverable 0-A) — durable in-repo knowledge preservation.
  Source: /Users/gc/Public/ADSQL/reports/2026-06-14-perf-maturity-status.md
  Consolidated & reconciled to HEAD in ../0003-codebase-health-and-perf.md
  Execution program in ../../rfcs/0009-health-and-perf-execution-program.md
  The content below is byte-for-byte unmodified; do not edit — edit 0003 instead.
-->

# ADSQL performance-maturity program — status, design & roadmap

_Date: 2026-06-14 · Repo: `/Users/gc/Developer/ongoing/swift/ADSQL` · Branch: `main`_
_Live plan file: `~/.claude/plans/prancy-noodling-diffie.md` · Perf commit: `8ddcc9a`_

> This is the engineering source-of-truth for the "beat SQLite everywhere" effort:
> the goal, the substrate, the measured gaps, what shipped, the full design of what
> remains, the correctness landmines, and how to measure. It is written to be picked
> up cold.

---

## 1. Goal, philosophy & the seven criteria

**Goal.** Make ADSQL (a from-scratch, pure-Swift, SQLite-compatible embedded engine for
macOS / Apple Silicon) beat system SQLite on *every* SQL workload, with **zero loss** of
correctness, durability, or concurrency guarantees.

**Philosophy (owner directive).** Do **not** replace code in place. For each performance
dimension, implement *every* alternative execution strategy **beside** the existing,
verified one; make them **configurable and tunable**; **benchmark all of them against seven
criteria**; and **remove nothing** until a strategy demonstrably wins on all seven. Defaults
stay at today's behavior until the data justifies a flip. The tree-walk evaluator and the
nested-loop join will likely remain *permanently* as correctness references and fallbacks.

**The seven criteria and how each is enforced:**

| criterion | enforcement mechanism |
|---|---|
| **accuracy** | every strategy's results identical to each other AND to the CSQLite oracle (`SQLiteMirror` in tests); strategy-matrix differential tests |
| **performance** | `ADSQLBench` latency percentiles (`LatencyHistogram`) + throughput (`formatRate`), per strategy, vs the SQLite arm |
| **concurrency** | `swift test --sanitize=thread` on every changed row/scan/write path |
| **parallelism** | the multi-reader `concurrent` scenario (readerCounts `[1,4,8,12,16]`) run per strategy → scalability curve |
| **reliability** | crash-injection (`SimulatedDisk` + `CommitRecoveryTests`: `barrierProfileSweepEveryCutGroup`, `randomizedCrashStorm`) per write/insert strategy |
| **consistency** | snapshot isolation holds identically under every strategy (multi-reader-during-write differential) |
| **integrity** | `Integrity.deepCheck` (page liveness + index⇄row bijection + `index.handle.count == table.handle.count`) + byte-identical canonical table dumps across insert strategies |

**Three pluggable dimensions** (selected by `ExecutionOptions`, per-database via
`DatabaseOptions.execution` or per-statement via `Statement.setExecutionOptions(_:)`):

| dimension | reference (default) | alternatives |
|---|---|---|
| **Evaluator** | `treeWalk` | `compiledClosures` ✅, `vdbe` (todo) |
| **Join** | `nestedLoop` | `hash` ✅, `merge` (todo), `auto` cost-based (todo) |
| **Insert** | `standard` | `hoisted` (todo), `appendCursor` (todo) |

---

## 2. Engine substrate (so the rest makes sense)

**Storage kernel (M0–M2, done long ago).**
- Copy-on-write B+tree over a reserve-max `mmap`; **16 KiB pages** (native on Apple Silicon),
  each XXH64-checksummed. Crash-safe *by construction*: committed pages are immutable;
  recovery = pick the newest checksum-valid meta page (ping-pong).
- **MVCC: single writer, wait-free readers.** Readers take a snapshot (a meta generation)
  with no locks held while reading pages; the writer's page-reclamation horizon can't pass a
  reader still acquiring its snapshot (reader-table + meta publication share one critical
  section). Commit = one `F_BARRIERFSYNC` (default `.barrier` durability) + meta ping-pong.
  Group commit batches writers. A dedicated large-stack writer thread runs `writeSync`.
- Free-list reclamation; overflow chains for large values; cross-process reader table.

**Relational layer (M3).**
- Strict typed `Value` (`.null/.integer(Int64)/.real(Double)/.text(String)/.blob([UInt8])`);
  `.text`/`.blob` carry **heap, ARC-managed** payloads (this matters a lot below).
- **`KeyCodec`** — order-preserving key encoding (memcmp order == `Value.keyOrder`):
  - `NULL=05`; `INTEGER=10‖BE8(bitPattern ^ 0x8000…)` (sign-flip); `REAL=18‖BE8(monotone(d))`
    (-0→+0); `TEXT binary=20‖escaped(utf8)‖00`; `TEXT nocase=21‖escaped(asciiFold(utf8))‖00`;
    `BLOB=28‖escaped(bytes)‖00`. Escaping (FoundationDB tuple scheme): payload `00`→`00 FF`,
    terminator a bare `00`. **Index entries = `encode(cols) ‖ 8-byte sign-biased rowid`;
    table-tree keys = the bare 8-byte rowid.** `decode` (new) is the inverse.
- **`RecordCodec`** — row records: `varint count ‖ tagged cells`
  (`00`null, `01`zigzag int, `02`8B-LE real, `03`varint-len+utf8 text, `04`varint+blob).
  `decodeOne` for a TEXT cell does `String(decoding:…)` — **a heap String alloc per text read.**
- Catalog (transactional DDL), DML (conflict policies, FK cascade, secondary-index
  maintenance), deep integrity checker.

**SQL front end (M4–M4.8).**
- Pipeline: lexer → **Pratt parser** → binder → heuristic planner → **row-at-a-time
  executor** → writer. `SQLExpr` is a `public indirect enum` (every node heap-boxed).
- The binder resolves column refs to `.boundColumn(table, column)` **slots** at bind time;
  a `Statement` (Sendable) caches one `BoundQuery` per `(catalogVersion, planningTag)` under a
  `Mutex`.
- **Evaluation:** `SQLEval.evaluate(SQLExpr, SQLEvalEnv)` — a recursive switch over the
  indirect enum. `SQLEvalEnv` is a struct of **~10 closures** (`parameter`, `column`,
  `boundColumn`, `collationOf`, `columnTypeOf`, `boundCollation`, `boundColumnType`,
  `scalarSubquery`, `aggregateValue`). A single `col = const` comparison fires: 2 `evaluate`
  recursions + 2 `boundColumnType` (affinity) + 2 `boundCollation` (collation) closure calls,
  **recomputed per row** even though the schema is fixed.
- **Row access:** `RowSlot` (`@safe`, holds a stored `UnsafeRawBufferPointer` into the mapped
  page) decodes a column **lazily on demand**, caches the `Value`, and walks the record header
  incrementally (no full offset table, no whole-record copy). `RowView` is the `~Escapable`,
  lifetime-checked public analogue. `RowContext` = one `RowSlot` per table + `nullExtended`
  flags; `forEachFilteredRow`/`descend` drive the nested-loop join, loading slots per row.
- **Planner:** heuristic, **no cost model**. `chooseIndex` scores `prefixLen*4 +
  trailing*2 + unique`. `planJoin` mirrors it for INLJ. `AccessPlan = tableScan | rowid |
  index | fts`. `TreeHandle.count` (live row count, on every table/index handle) exists but
  was unused for planning — it is the cost-model input (no ANALYZE needed).

---

## 3. Why SQLite is faster where it is (profiling)

Profiled with `/usr/bin/sample` (1 ms) on `ADSQLBench sql`, attributing self-time to symbols.

**SQLite's hot stack is lean:** `sqlite3VdbeExec` (one flat bytecode loop) +
`sqlite3BtreeTableMoveto`/`IndexMoveto` + `memcmp`/`vdbeRecordCompareString` on raw page
bytes. **No malloc, no refcounting, no String materialization** in the leaders;
`guarded_pwrite_np` (insert I/O) tops it.

**ADSQL's hot stack is dominated by language-runtime overhead SQLite never pays** (search+insert
profile, self-time samples):

- `swift_beginAccess`+`endAccess` ≈ **1070** — dynamic exclusivity checks on **class-property
  mutation inside per-row loops** (`Accumulator.rows/sortKeys/seenRowids`, `RowSlot.cache/
  offsets`, `RowContext.nullExtended`).
- ARC churn ≈ **2300+** (`swift_release/retain/isUniquelyReferenced/bridgeObject*/allocObject/
  deallocClassInstance/arrayDestroy`) — `Value` boxing String/[UInt8], `[Value]`/`[[Value]]`
  CoW, `GroupKey`.
- malloc family ≈ **900**; `String(decoding:)` per TEXT read (`RecordCodec.decodeOne`);
  `SQLCompare.compareUTF8` (byte-iterator compare, not `memcmp`).
- `Node.search` (513) — B-tree descent; `SQLEval.evaluate` (552 in one run) — the tree-walk.

**Per-scenario attribution (CPU share):** JOIN > DISTINCT > SEARCH. Root causes:
- **DISTINCT** (`SELECT DISTINCT framework,kind`, ~12 distinct of 200k): `project()` built a
  `[Value]` for *all 200k* rows then a `Set<GroupKey>` dedup — materialize-then-dedup, no
  index. (Now fixed via index-ordered dedup.)
- **SEARCH** (`WHERE fw=? AND kind=? ORDER BY key LIMIT 20`): the `(fw,kind)` index doesn't
  cover `key`, so each of ~8k matches/query **descends to the table** for `key`, String-decodes
  it, and feeds the top-20 (String alloc per match). (Now: zero-copy top-N.)
- **JOIN** (`COUNT(*) … ON b.key=a.key`, unique key): per outer row, an index→table descent +
  `b.key` decode + a redundant ON re-check. (Now: existence probe; residual is per-probe
  `KeyCodec.encode` + `a.key` String decode + the inherent index seek.)

---

## 4. Current scorecard (vs system SQLite, 200k rows, this machine)

| scenario | ADSQL | SQLite | ratio | notes |
|---|---|---|---|---|
| cold open → first get | leads | — | ~5–13× | pre-existing |
| point get / rowid get (p50) | ~0.8–4 µs | ~2–5 µs | ~3× | pre-existing |
| raw KV scan | ~4.9 GB/s | ~4.0 GB/s | ~1.2× | pre-existing |
| 16 concurrent readers | ~1.07 M/s | ~0.47 M/s | ~2.3× | pre-existing |
| **DISTINCT** | **4.3 ms** | 9.9 ms | **2.3× faster** ✅ | was 0.08× |
| **SEARCH** (p99) | **~5.4 ms** | ~5.3 ms | **≈ parity** ✅ | was 0.44× |
| **JOIN** (COUNT(*) self-join) | **164 ms** | 42.8 ms | **0.26×** ⚠️ | was 0.12× |
| **INSERT** (batch, 3 idx) | **161 k/s** | 209 k/s | **0.77×** ⚠️ | was 0.70× |

**Caveats:** absolute numbers vary with thermal/load — always compare **back-to-back in one
session**. SEARCH's **p50 is bimodal** (see §10). Earlier "before" numbers were taken under
profiler/build load and are ~2–3× inflated vs clean; the *ratios* are stable. **Only JOIN and
INSERT still lose.**

---

## 5. What shipped (committed `8ddcc9a`) — mechanisms + validation

All of the following are committed, default-on where they're pure wins, and validated:
full suite + new differential/property suites green; `-strict-memory-safety` clean;
ThreadSanitizer clean on changed paths; crash-injection green.

**Targeted perf fixes (now the default path):**

| fix | mechanism | files | result |
|---|---|---|---|
| DISTINCT streaming dedup | dedup into a `Set<GroupKey>` during the scan (kept-set, not 200k rows) | `Executor.swift` `Accumulator` | memory-bounded |
| **DISTINCT index-ordered** | scan a covering index in key order; **adjacent-dedup** by raw key-prefix bytes; decode distinct values from the key (no table descent) via **new `KeyCodec.decode`** | `Executor.swift` `runDistinctIndex`, `KeyCodec.decode`, `Plan.swift` `distinctIndexName` | 123→**4.3 ms**, beats SQLite |
| referenced-cols + COUNT(*) guard | bind-time `(table,column)` reference set; skip materializing a group representative no output/HAVING/ORDER BY reads | `Plan.swift`, `Executor.swift` `runAggregated` | enables join existence |
| **JOIN existence probe** | `fastExistence`: UNIQUE-index full-key equality → **single seek** (A4 seek+`isValid`+prefix-`elementsEqual`) with a **zero-copy probe key** built from the outer column's page bytes; no descent, no ON re-check, no materialization | `Executor.swift` `fastExistence`/`appendProbeField`, `RowSlot.withTextBytes`, `KeyCodec.append*` | 395→164 ms |
| **SEARCH zero-copy top-N** | single-text-column ORDER BY: compare the candidate's sort-key **bytes in place** vs the worst kept entry; materialize only on the cut (B4 NULL-first+DESC) | `Executor.swift` `Accumulator.fastDropsCandidate`, `Eval.swift` raw `compareUTF8`/`NoCase` | ≈ parity |
| INSERT buffer reuse | reuse per-txn record/index **encode scratch buffers** (`putBytes` copies into the page) | `DML.swift`, `TxnContext.swift`, `RecordCodec.encode(into:)`, `KeyCodec` | +9% |

**Maturity-program foundation (alternatives selectable; defaults unchanged):**

- **Phase 0 — config + seam.** `ExecutionOptions` (Sendable value, snapshot-copied per
  execution → no shared mutable state, MVCC untouched). `DatabaseOptions.execution` +
  `Statement.setExecutionOptions`. Plan cache keyed on `(catalogVersion, planningTag)` so a
  plan bound under one join strategy is never reused under another.
- **Phase 2 — compiled-closure evaluator** (`CompiledEval.compile`). Lowers each bound
  `SQLExpr` to a typed-throws closure tree **once**, reading slots straight from `RowContext`
  (no env closure) and **baking affinity + collation at bind time** (the per-row recompute the
  profiler fingered). Mirrors `SQLEval.evaluate` exactly; **returns nil → tree-walk fallback**
  for any unsupported node (correct-by-construction). Wired to the single-table scan path
  (`Accumulator` residual/projection/ORDER-BY thunks). Measured **distinct ~23%, search ~9%**
  faster on covered scans. Validated `treeWalk ≡ compiled ≡ SQLite` (`SQLStrategyMatrixTests`,
  13 cases incl. binary/NOCASE/explicit-COLLATE/arithmetic/AND-OR/CASE/cast/concat).
- **Phase 3a — hash join** (`runInnerHashJoin`). 2-table INNER equi-join: build a
  `[GroupKey:[(rowid,values)]]` hash of the inner (full scan + `materialize`), probe the outer;
  produces the **same composite `RowContext` state** (new `RowSlot.loadMaterialized` /
  `RowContext.loadMaterialized`) so projection/WHERE/aggregation are unchanged. Self-extracts
  equi-keys from the bound ON; restricted to **same-class/same-collation column=column** keys;
  non-equi conjuncts re-checked per match; **NULL probe keys match nothing**; memory-budget
  fallback. Validated `nestedLoop ≡ hash ≡ SQLite` (`SQLHashJoinTests`, 8 cases incl. fan-out,
  multi-key, residual ON, type-mismatch & LEFT fallbacks).
- Bench flags `--eval`, `--join`, `--point-gets`; seeded strategy-matrix differential harness.

---

## 6. Critical empirical findings (these dictate the roadmap)

1. **Hash join is the WRONG tool for the symmetric self-join.** Measured **716 ms vs
   nested-loop 186 ms** — it materializes all 200k inner rows. Hash join wins on **unbalanced**
   joins (small build side); it must never be chosen for a large symmetric join. ⇒ **the cost
   model is mandatory**, not optional.
2. **The JOIN-benchmark winner is the MERGE join.** Both sides share the sorted
   `u_documents_key`, so a single O(N) lock-step merge — byte-compare keys, no materialization,
   no per-probe descent — can **beat** SQLite. Not yet built.
3. **A hash semi-join** (when the inner is `innerExistenceOnly`, e.g. COUNT(*): build key
   *counts*, don't materialize) makes hash competitive even on the symmetric benchmark.
4. **Compiled-evaluator's projected 3–5× needs broader coverage** — today only the single-table
   scan path. The big wins are on **comparison-heavy table-scan WHEREs** (affinity baking) and
   the **join ON / aggregate** paths.
5. **INSERT's safe wins are workload-narrow.** State-copy/index-sort/cursor-reuse matter on
   *many-index* DBs (~13% there); on the apple-docs shape (1 table, 3 indexes) they're a few %.
   The real lever is the **crash-critical `appendCursor`** for sequential-rowid appends.

---

## 7. Remaining work — detailed designs

### 7.1 JOIN: beat SQLite (highest value)

**(a) Merge join** — `MergeJoin` (new), dispatched from `forEachFilteredRow` when
`execution.join == .merge` and eligible.
- *Eligibility:* a 2-table equi-join where **both** sides expose a sorted index on the join
  key column(s) in the same order with the **same collation** (detect via the index records +
  `Planner` order analysis `indexYieldsOrder`/`orderColumns`).
- *Algorithm:* open a `Cursor` on each side's index (key order). Lock-step: compare the two
  current keys (byte compare on the key-prefix, A4-style minus the rowid suffix); advance the
  smaller. On equality, gather the **dup run** on each side (all consecutive entries with the
  equal key) and emit the cross-product (load both slots per pair → `body`). LEFT: emit one
  null-extended row for an outer key with no inner match.
- *Existence/COUNT(*) fast path:* when the inner is `innerExistenceOnly`, **no table descent** —
  just multiply run lengths into the match count and `emit()` that many times. This is the
  O(N) byte-only pass that beats SQLite on the benchmark.
- *Referenced columns:* descend by rowid per emitted row (or read from a covering index value).
- *Correctness:* use the index collation; NULL keys never match (skip a NULL run); dup runs
  cross-product exactly; validate against `nestedLoop`/`hash`/SQLite in the matrix.

**(b) Cost model `.auto`** — `Planner.planJoin` + a new `BoundJoin.driver: ExecutionOptions.Join`.
- Estimate per candidate using `TreeHandle.count` (outer `M`, inner `N`) + equality
  selectivity (unique index ⇒ ≤1 inner match; else `N / distinct`):
  - INLJ ≈ `M · log N` (+ per-probe `KeyCodec.encode`/seek constant)
  - hash ≈ `M + N` (+ build memory; only if build fits the budget) — **build the smaller side**
  - merge ≈ `M + N` (only if both sides sorted on the key)
  - pick the minimum; tie → `nestedLoop`. `.nestedLoop/.hash/.merge` force a driver (for
    validation/bench).
- Already wired: `planningTag` is in the plan-cache key, so `.auto` plans aren't reused across
  strategies. Superset-preserving (the leaf re-applies ON/WHERE), so a wrong estimate only
  changes *speed*, never results.

**(c) Hash semi-join** — in `runInnerHashJoin`, when `join.innerExistenceOnly && onResidual ==
nil`: build `[GroupKey: Int]` (key → count of inner rows), probe the outer, `emit()` `count`
times — **no inner materialization**. (Needs an *indexed* fixture in tests so
`innerExistenceOnly` is actually set — `SQLJoinExistenceTests` shape.)

### 7.2 INSERT: beat SQLite

**(a) `hoisted` (safe; no COW/split change).** A `Relation.insertBatch(…, plan: InsertPlan)`
where `InsertPlan` precomputes once per statement: the table/state fetch, the **sorted
owned-index and unique-index lists** (today rebuilt every row at `DML.swift:~363/~405`), and
reusable per-index conflict cursors. Mutate `ctx.relation` **in place** to avoid the per-row
`RelationState` struct copy + dictionary CoW. Keep `insertCore` as the single-row reference.
Differential vs `standard` (results + RETURNING + **byte-identical table dump**) + deep
integrity + crash-injection per strategy.

**(b) `appendCursor` (crash-critical; the real lever).** New `AppendCursor.swift` + a per-tree
warm cache on `TxnContext` (writer-confined, not Sendable): the rightmost leaf (pageNo + dirty
`PageBuf`) + its max key + the tree's `rootPage` (for staleness). For **strictly ascending
rowid** inserts to the table tree: if the new key sorts after the cached max **and fits in the
rightmost leaf without a split**, append in place and bump `count`. **Any** of {non-ascending
key, leaf full / would split, stale cache vs `tree.rootPage`} falls through to the proven
`BTree.put` (`BTree.swift:117`) — so the dangerous split + `insertSeparator` propagation always
uses the verified path. Invalidate the cache on the first non-append mutation to that tree, on
**request rollback** (`TxnContext.rollbackRequestScope` — keeps group commit correct), and on
DDL. It can never produce a structurally different tree — only skip the root descent when
provably safe. **Hard gate:** crash-injection (`barrierProfileSweepEveryCutGroup`,
`randomizedCrashStorm`), especially mid-split; drop if not spotless.

### 7.3 EVALUATOR: widen every lead

- Extend `CompiledEval` coverage to: the **join ON** (`descend`), the **residual/WHERE on
  filtered table scans** (already compiled in `Accumulator`), and **aggregate finalization**.
  The aggregate env (`aggregateEnv`) differs per group (reads the group representative +
  accumulators) — don't recompile per group; compile the finalization exprs once against a
  **swappable "current group" holder** captured by reference. Also add `.like`, `.inList`,
  `.function` (compile args + delegate to `SQLFunctions.call`) to `CompiledEval.compile`
  (currently they fall back).
- **Phase 4 — VDBE register machine** (`Sources/ADSQLKernel/SQL/VDBE/`). A flat opcode loop
  over a register file, the structural end-state that matches `sqlite3VdbeExec`.
  - Files: `Opcode.swift` (~20–25 ops: `OpenScan/Seek`, `Column(slot)`, `Rowid`, `Literal`,
    `Param`, `Affinity`, `Compare(op)`, `And/Or/Not/IsNull`, `Add/Sub/Mul/Div/Mod/Neg`,
    `Concat`, `AggStep/AggFinal`, `MakeKey/Sort/TopN`, `Jump/JumpIf`, `ResultRow`, `Halt`);
    `Program.swift` (instructions + register `[Value]` + a `Compiler` lowering `BoundSelect`);
    `Machine.swift` (`VDBEEvaluator: RowEvaluator`, reads columns through `RowContext`/`RowSlot`
    to reuse zero-copy decode + the `@safe` span — stays strict-memory-safe; registers are
    `[Value]`, no raw pointers).
  - Ships incrementally: the compiler returns nil for unsupported constructs → that statement
    falls back to `treeWalk`. Single-table first, then joins/aggregates. Multi-week.

### 7.4 Cross-cutting infrastructure

- **Multi-criteria bench harness** — `Sources/ADSQLBench/StrategyBench.swift` + `--strategy-
  matrix`. Per scenario × strategy, report all seven criteria: performance (percentiles +
  throughput); concurrency/parallelism (the multi-reader `concurrent` scenario per strategy +
  an optional parallel-execution evaluator variant as the scalability headline); reliability
  (crash-injection pass/fail per insert strategy); integrity (`deepCheck` + `IntegrityReport`
  after each). Keep the CSQLite arm as the external baseline beside the per-strategy rows.
- **Grow the differential matrix** (`SQLStrategyMatrixTests`) as each strategy lands — every
  combo of `Evaluator × Join × Insert` must agree with each other and SQLite, and leave
  byte-identical DB state. **This is the gate that lets code be retired.**

### 7.5 Phase 5 — selection & retirement (the ONLY place code is removed)

Flip defaults per dimension **only after** a strategy wins on **all seven criteria**
(candidates: `join = .auto`; evaluator → compiled or vdbe; insert → hoisted/appendCursor).
Retire a superseded path only once its replacement is proven, and prefer keeping it selectable
for one release (bisection). Update `ROADMAP.md` + `docs/rfcs/`.

---

## 8. Correctness landmines (honor every one)

- **A4 — index key layout.** Stored index keys are `encode(columns) ‖ 8-byte rowid`. A bare
  `Cursor.seek(prefix)` returns `exact == false` even when a matching row exists. Existence
  must use **seek + `isValid` + prefix-`elementsEqual`** (the `Relation.firstRowid` shape).
  `KeyCodec.decode` requires the caller to have **stripped the rowid suffix** (a terminator
  `00` followed by a suffix byte `FF` would be misread as an escaped null).
- **B4 — DESC + NULL.** The descending flip applies to the **final** comparison only;
  NULL-sorts-first (ASC) must be preserved exactly as `orderCompare` does.
- **`GroupKey` equality vs SQL `=`.** `GroupKey` canonicalizes numeric classes (1 ≡ 1.0) and
  folds NOCASE; it equals SQL `=` **only for same-class/same-collation** operands. Hash/merge
  join keys are therefore restricted to same-class/same-collation column=column (no affinity
  coercion ⇒ no false negatives); the non-equi residual ON is re-checked at each match. A
  mismatched type/collation join falls back to nested-loop.
- **`KeyCodec.decode` NOCASE lossiness.** NOCASE text is folded at encode time, so decode
  yields the **folded** bytes, not the original. Index-ordered DISTINCT **excludes NOCASE-text
  columns** (the binder gate); INTEGER/REAL/BINARY-text/BLOB/NULL round-trip losslessly.
- **Affinity baking.** The compiled evaluator bakes the **schema-fixed affinities/collation**
  at compile time but applies the *value* coercion at runtime (the runtime value class is still
  checked) — semantically identical to `SQLEval`, only the timing changes.
- **Type-boundary gate.** Zero-copy probe-key/hash-key paths engage only when the outer column
  class == the index/inner class; otherwise fall back to the `Value`-coercing path (which
  handles int↔real, text↔int affinity, and proven-empty cases).
- **Empty-span safety.** An existence-only inner slot is loaded with an empty span; safe
  *because* the inner is unreferenced (`value(at:)` is never called; `RowSlot` decodes lazily).
- **NULL join keys.** `NULL = NULL` is unknown → no match. Hash/merge skip NULL probe keys;
  build-side NULL entries are never matched.
- **Exclusivity.** Class-property mutation in per-row loops triggers `swift_beginAccess`
  (~1000 samples). Mitigate by accumulating into **local `var`s** the optimizer can prove
  exclusive — **never** by disabling exclusivity enforcement (that drops a memory-safety check).

---

## 9. Risk register

| risk | severity | mitigation |
|---|---|---|
| `appendCursor` vs split / group-commit undo | **HIGH** | defer every split to `BTree.put`; invalidate warm cache on rollback; crash-injection mid-split |
| evaluator semantic drift (compiled/VDBE affinity/collation/3VL) | **HIGH** | mirror `SQLEval` exactly; full-corpus differential matrix; nil → tree-walk fallback |
| hash-join memory blowup | MED | budget knob (`hashJoinMemoryBudgetBytes`) + nested-loop fallback; build smaller side |
| merge-join dup-run / collation | MED | restrict to provably-sorted-both-sides; differential fuzzing |
| plan-cache reuse across planning-relevant options | MED | `planningTag` in the cache key (done) |
| concurrency regressions | LOW | `ExecutionOptions` is read-only `Sendable` data snapshot-copied per execution; no new shared mutable state; TSan every change |

---

## 10. Measurement methodology

- **Bench:** `swift run -c release ADSQLBench sql --engine adsql|sqlite --point-gets N
  --eval treeWalk|compiled|vdbe --join nestedLoop|hash|merge|auto`. `--point-gets` controls the
  search/key iteration count (default 30k → ~260 s; use a few hundred/thousand for fast loops).
- **SEARCH p50 is bimodal — use p99.** The dataset writes `framework[i%6]` and `kind[i%4]`, so
  only **12 of 24** `(framework,kind)` combos are populated. A random query hits an empty combo
  ~50% of the time (~20 µs) vs a populated one (~5 ms), so the median sits on the cliff. p99 is
  the populated-query (worst-case) signal.
- **Profiling:** `/usr/bin/sample <pid> <secs> 1 -file out.txt -mayDie`; attribute via the
  `SQLScenario.swift` call-site line numbers (insert/key/search/distinct/join each have a
  distinct `Statement.all(_:)` call site) and the "Sort by top of stack" self-time section.
- **Machine variance is real** (thermal/background load shift absolutes ~2–3×). Always compare
  strategies **back-to-back in one session**; trust ratios over absolutes.

---

## 11. Quick reference

**Config / dispatch:** `Sources/ADSQLKernel/SQL/ExecutionOptions.swift`; `Database.swift`
(`DatabaseOptions.execution`); `Statement.swift` (`setExecutionOptions`, `effectiveExecution`,
plan cache `planningTag`).

**Evaluator:** `Eval.swift` (treeWalk + `applyAffinities` + raw `compareUTF8`/`NoCase`) ·
`CompiledEval.swift` · (future) `SQL/VDBE/`. Seam: `Accumulator` thunks built in
`SelectExecutor.run`.

**Join:** `Executor.swift` `runInnerHashJoin` / `forEachFilteredRow` / `descend` /
`fastExistence` · `Planner.planJoin` (+ future `BoundJoin.driver`) · `MergeJoin.swift` (todo).

**Insert:** `Relation/DML.swift` `insertCore`/`insertBatch` · `AppendCursor.swift` (todo) ·
`BTree.swift` `put`/`insertSeparator` · `TxnContext.swift` (scratch buffers, warm cache).

**Reuse:** `GroupKey` (`Grouping.swift`), `Integrity.deepCheck` (`Integrity.swift`),
`SimulatedDisk` (`Tests/ADSQLTestSupport`), `TreeHandle.count` (`MetaPage.swift`),
`KeyCodec.decode`, `RowSlot.withTextBytes`/`loadMaterialized`, `RowView`.

**Differential / property suites:** `SQLStrategyMatrixTests` (evaluators), `SQLHashJoinTests`,
`SQLJoinExistenceTests`, `SQLSearchTopNTests`, `SQLDistinctIndexTests`, `RelationCodecTests`
(KeyCodec round-trip + byte-encode equivalence), `SQLEvalTests` (raw comparator equivalence).

**Gates (every change):** `swift build` (strict-memory-safety clean) · `swift test` (incl.
CSQLite differential + strategy matrix) · `swift test --sanitize=thread` (row/scan/write) ·
crash-injection (write paths) · `ADSQLBench` no-regression on the default config.

---

## 12. One-line status

DISTINCT and SEARCH now meet-or-beat SQLite; **JOIN (0.26×) and INSERT (0.77×) remain** — the
pluggable-strategy machinery, the compiled evaluator, and a (correct-but-not-yet-default) hash
join are in; **merge join + cost model** are the next step to beat SQLite on joins, and
**`appendCursor`** on inserts.

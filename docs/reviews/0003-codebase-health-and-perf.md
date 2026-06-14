# Review 0003 — Codebase Health & Performance: Consolidated Findings, Status & Program

**Date:** 2026-06-14 · **Repo:** `/Users/gc/Developer/ongoing/swift/ADSQL` · **Branch:** `main`
**HEAD at consolidation:** `2d5f347` (FTS F6n; the F6 line is under **active concurrent iteration** — RFC 0008 is the live FTS tracker) · **Reports' baseline:** `1c3bccf` · **Perf commit:** `8ddcc9a`
**Toolchain:** Swift 6.2 language mode / 6.4 toolchain · `.strictMemorySafety()` (SE-0458) + experimental
`Lifetimes` (SE-0446/0456) on `ADSQLKernel` · `platforms: [.macOS(.v26)]` · **zero runtime dependencies.**
**Build/test status (reports' baseline):** `swift build` clean (0 warnings); `swift test` green — 330 tests / 76 suites.

> **Purpose & provenance.** This review is the **single, durable, in-repo knowledge store** for the
> whole-codebase health check **and** the "beat SQLite everywhere" performance-maturity program. It
> **consolidates and reconciles to HEAD** two external status reports, archived verbatim alongside it:
> - `docs/reviews/archive/2026-06-14-health-check-remaining-work.md` — the quality/health audit.
> - `docs/reviews/archive/2026-06-14-perf-maturity-status.md` — the performance-maturity program.
>
> Nothing from those reports is condensed away: the archive is byte-for-byte, and this document carries
> their full substance plus the **delta since baseline** (§1.1) and the new whole-tree findings (§5).
> The **operational execution program** (phases, gates, live status) lives in
> `docs/rfcs/0009-health-and-perf-execution-program.md`. Milestone source of truth remains `ROADMAP.md`;
> the FTS/DSL act schedule remains `docs/rfcs/0008-execution-schedule.md`.

---

## 1. Executive verdict

ADSQL is an **exceptionally disciplined codebase** — among the cleanest storage engines reviewable.
Typed `throws(DBError)` is universal below the public façade and the claim holds *exactly*; the
strict-memory-safety audit (Review 0001) is genuinely resolved; MVCC concurrency, atomics orderings,
crash recovery, the free-list reclamation horizon, and the disk-**value** decoders are correct and
bounds-checked. Nothing is systemically wrong. The remaining gaps are **narrow and specific**:

1. **Reliability/integrity** — one real read-path gap (page-structure fields trusted on the hot path)
   was **fixed** during the health engagement (R1/R2).
2. **Consistency / Apple-native safe types** — a `strerror` thread-safety bug and a BE-decode
   inconsistency, both **fixed** (R3/C3); plus a remaining scoped strong-typedef opportunity (C).
3. **Structure / separation of concerns** — god-files (S2; **now six**, not three — see §1.1/§5) and an
   over-broad public surface (S1) **remain**.

On performance: **DISTINCT and SEARCH now meet-or-beat SQLite; FTS ranked top-k now BEATS SQLite FTS5**
(the headline change since the reports — §1.1, §4.4). The JOIN — formerly the engine's worst loss
(~0.26×) — **now beats SQLite (~2.1×)** via a merge-join existence fast path that the `.auto` cost model
selects, and `.auto` is now the **default** join strategy (won all seven criteria; RFC 0009 H4/H8).
**INSERT (~0.77×) is the one remaining losing SQL path**: its safe per-row waste-clears (rowid cache,
opt-in `appendCursor`) are in and tested, but the 3-index apple-docs shape is dominated by secondary-index
COW maintenance, so closing it needs index-maintenance work (a separate lever). A unifying finding (§5.7): the residual cost on JOIN, SEARCH **and** FTS-MATCH is the
**same per-row `[Value]`/ARC/exclusivity row-materialization** path — one evaluator/row-path lever
closes all three.

### 1.1 What changed since the reports' baseline (`1c3bccf` → `f0e0e5b`)

The reports were written at `1c3bccf`. The FTS "F6" line is under **active concurrent iteration** by a
peer worker — `f827ba7` F6g → `f0e0e5b` F6k → `e2522d3` F6l → `ad09d31` F6m → `2d5f347` F6n landed
during this consolidation (HEAD = `2d5f347`). The delta vs baseline is **almost entirely FTS** (the
`FTS/` files + the `docs/rfcs/0008` live status table) plus small `Executor.swift`/`Cursor.swift` seams;
the SQL JOIN/INSERT hot paths are **unchanged**, so the perf report's SQL scorecard still stands pending
the Phase-0 re-baseline. **For the live FTS micro-status, `docs/rfcs/0008-execution-schedule.md` is the
source of truth** (bumped every FTS slice). The material changes:

- **FTS ranked top-k went from ~3.7× *slower* to ~2.3× *faster* than SQLite FTS5** (p50 187µs vs 426µs)
  across F6i/F6j/F6k. The perf report predates and omits this; §4.4 adds the FTS scorecard.
- **Three more files crossed the 600-line target** since the report measured the top three (§5.1).
- The FTS **frame-of-reference postings codec** (F6g) and **zero-copy `docLength`** (F6k) are new code
  to audit for memory-safety (done — sound; §5.8) and idiom (two micro-fixes; §5.8).

---

## 2. Architecture & design model (as built, re-verified at HEAD)

A single Swift module, `ADSQLKernel`, organized by folder; a thin public façade `ADSQL`
(`@_exported import ADSQLKernel` + `ADSQLInfo`) re-exports it; `ADSQLTool` (CLI) and `ADSQLBench`
(benchmarks vs system SQLite) sit on top.

```
ADSQLBench / ADSQLTool        (executables)
        │
      ADSQL                   (façade: @_exported import ADSQLKernel + ADSQLInfo)
        │
   ADSQLKernel  ── ADCAtomics (C shim: cross-process u64 acquire/release/CAS)
     ├─ (root)   VFS, mmap, COW B+tree, pager, MVCC, free-list, commit, recovery, integrity
     ├─ Relation/ catalog, DML, definitions, key/record codecs, rows, values, FKs, civil-time
     ├─ SQL/      lexer, parser, AST, planner/binder, plan, executor, eval, functions, JSON, pragma
     └─ FTS/      tokenizers (unicode61/porter/trigram), postings, scorer (bm25/bm25f), WAND, match, triggers
```

**Design pillars (do not undo):**
- **Copy-on-write B+tree over `mmap`.** Committed pages are immutable; a write shadows pages root→leaf
  into freshly allocated page numbers (`TxnContext.shadow`), publishing a new meta only after data+barrier.
- **Single-writer / wait-free reader MVCC.** Any number of readers run lock-free over an immutable
  snapshot (a `Meta` generation). One writer at a time (serial `WriterThread` + `fcntl(F_WRLCK)`).
  Readers register a generation; the writer's reclamation horizon never passes a live reader.
- **Crash-safe by construction.** No WAL/undo log: recovery = pick the newest checksum-valid meta page.
  Reuse of freed pages lags one generation, so recovery to N−1 is always sound.
- **Zero dependencies; mature syscall layer.** `clonefile(2)` snapshots, `F_PREALLOCATE`/`F_NOCACHE`,
  `F_BARRIERFSYNC`/`F_FULLFSYNC` durability profiles, `mmap`+`madvise(MADV_RANDOM)`.
- **Strict memory safety.** Every unsafe construct is marked `unsafe` or encapsulated by a `@safe` type;
  the two highest-exposure borrowed page views are compiler-enforced `~Escapable` over `RawSpan`.

### 2.1 On-disk format & integrity model (verified, current tree)

- **Page = 16 KiB** (native on Apple Silicon). Pages 0/1 are the two meta pages (ping-pong by
  `generation % 2`, `Meta.pageNo` at `MetaPage.swift:48`); data pages start at `Format.firstDataPage = 2`.
- **Per-page checksum:** XXH64 over page bytes `8..<16384` **seeded with the page number** —
  `PageHeader.stampChecksum` (`Page.swift:100`) / `verifyChecksum` (`Page.swift:105`). Stamped once per
  dirty page at commit.
- **Commit protocol** (`Committer.commit`, `Committer.swift:18`; doc at `:8–14`): write all data pages →
  barrier → flip the meta. `newMeta.generation = old + 1` (`:28`). A torn in-flight meta falls back one
  generation (`:12`, `:62`).
- **Recovery / meta selection** (`Meta.recover`, `MetaPage.swift:145`): highest-`generation`
  **checksum-valid** meta wins (`:158`); both-invalid is fatal (`DBError.bothMetasInvalid`).
- **Reclamation horizon (closes the page-recycling UAF, CWE-416):** a reader publishes its min generation
  via `ReaderTable.publish` → `adc_store_release_u64` (`ReaderTable.swift:126–128`); the writer reads
  slots via `adc_load_acquire_u64` (`minimumGeneration`, `:133–137`), takes `min(localMin, foreignMin)`
  (`WriterLoop.swift:74`), and `reclaimLimit = min(minReader, generation−1)` (`Meta.reclaimLimit`,
  `MetaPage.swift:56–57`). A harvested page is provably unreferenced by any tree a live reader can see.
- **Single-writer & lifecycle:** writer lock `fcntl(F_WRLCK)` held for the handle's life
  (`ReaderTable.swift:69`); double-close guarded by `didShutdown.exchange(true, ordering:
  .acquiringAndReleasing)` (`WriterThread.swift:155`).
- **Cross-process atomics:** the `ADCAtomics` C shim exposes `adc_load_acquire_u64`/`adc_store_release_u64`
  (`Sources/ADCAtomics/include/adcatomics.h:12,17`) over `MAP_SHARED` lock-file slots — the one thing
  stdlib `Synchronization.Atomic` cannot do (it owns its storage; can't alias a chosen mmap offset across
  processes).
- **Untrusted-input decoding:** record/key/overflow/varint decoders validate every on-disk length against
  the buffer **before** slicing (e.g. `RecordCodec.swift:158–166, 210–224`; `KeyCodec.decodeField`/
  `readBE`/`readEscaped`; `Varint.read` overflow guard). This is the well-guarded part of the integrity
  surface. **Threat model:** a database file is an attacker-controllable input surface; trusted-file by
  default, with `verifyChecksumsOnRead` for untrusted files (§3.1, R1).

### 2.2 Engine substrate detail (relational + SQL layers)

- **Strict typed `Value`** (`.null/.integer(Int64)/.real(Double)/.text(String)/.blob([UInt8])`);
  `.text`/`.blob` carry **heap, ARC-managed** payloads (this matters a lot for the waste catalog, §5).
- **`KeyCodec`** — order-preserving key encoding (`memcmp` order == `Value.keyOrder`): `NULL=05`;
  `INTEGER=10‖BE8(bitPattern ^ 0x8000…)` (sign-flip); `REAL=18‖BE8(monotone(d))` (-0→+0);
  `TEXT binary=20‖escaped(utf8)‖00`; `TEXT nocase=21‖escaped(asciiFold(utf8))‖00`;
  `BLOB=28‖escaped(bytes)‖00`. Escaping (FoundationDB tuple scheme): payload `00`→`00 FF`, terminator a
  bare `00`. **Index entries = `encode(cols) ‖ 8-byte sign-biased rowid`; table-tree keys = the bare
  8-byte rowid.** `KeyCodec.decode` is the inverse.
- **`RecordCodec`** — row records: `varint count ‖ tagged cells` (`00`null, `01`zigzag int, `02`8B-LE
  real, `03`varint-len+utf8 text, `04`varint+blob). `decodeOne` for a TEXT cell does `String(decoding:…)`
  — **a heap String alloc per text read** (§5.5). Zero-copy `withText`/`withBlob` exist
  (`RecordCodec.swift:123–185`) and an incremental, allocation-free `cellOffsets`/`skipCell` walk.
- **SQL pipeline:** lexer → **Pratt parser** → binder → heuristic planner → **row-at-a-time executor** →
  writer. `SQLExpr` is a `public indirect enum` (every node heap-boxed). The binder resolves column refs
  to `.boundColumn(table, column)` **slots** at bind time; a `Statement` (Sendable) caches one
  `BoundQuery` per `(catalogVersion, planningTag)` under a `Mutex`.
- **Evaluation:** `SQLEval.evaluate(SQLExpr, SQLEvalEnv)` — a recursive switch over the indirect enum.
  `SQLEvalEnv` is a struct of ~10 closures. A single `col = const` comparison fires 2 `evaluate`
  recursions + 2 affinity + 2 collation closure calls, **recomputed per row** even though the schema is
  fixed — the per-row recompute the profiler fingered, addressed by `CompiledEval` (§3.2).
- **Row access:** `RowSlot` (`@safe`, holds a stored `UnsafeRawBufferPointer` into the mapped page)
  decodes a column **lazily on demand**, caches the `Value`, and walks the record header incrementally
  (no full offset table, no whole-record copy). `RowView` is the `~Escapable`, lifetime-checked public
  analogue. `RowContext` = one `RowSlot` per table + `nullExtended` flags; `forEachFilteredRow`/`descend`
  drive the nested-loop join.
- **Planner:** heuristic, **no cost model yet**. `chooseIndex` scores `prefixLen*4 + trailing*2 + unique`;
  `planJoin` mirrors it for INLJ. `AccessPlan = tableScan | rowid | index | fts`. `TreeHandle.count` (live
  row count, on every handle) exists and is the **cost-model input** (no ANALYZE needed) — currently
  unused for planning.

---

## 3. What's already excellent (do **not** re-propose) & what was fixed

### 3.1 Settled, verified-good (do not relitigate)

- **Typed throws are exact.** Zero untyped `throws` below the façade; the kernel is `throws(DBError)` end
  to end. Untyped `throws` exists only in `ADSQLBench`.
- **Review 0001 fully resolved (re-verified):** `RowView` (`Rows.swift:40`) and `BTree.ValueRef` are
  genuine `~Copyable, ~Escapable` over `RawSpan`, lifetime-bound to the snapshot resolver via
  `_overrideLifetime`; `MMap.base` is `private`; `PageBuf.raw` is `internal`; the `_unsafeBytes:` SPI is
  confined to one `ReadTxn.withRawSpan` bridge; **zero** `nonisolated(unsafe)` anywhere in `Sources/` or
  `Tests/`.
- **Concurrency-race correctness:** atomic orderings correct, single-writer enforced, double-close
  idempotent, recovery sound — no findings.
- **Disk-value decoders** rigorously bounds-check before slicing (§2.1).
- **No material duplication** (varint centralized in `ByteCodec.Varint`); **no dead code**
  (`TrigramTokenizer` is live via `Tokenizer.swift`); debt markers are false positives (SQL keyword
  strings, not TODOs).
- **`Sendable` discipline is clean:** every `@unchecked Sendable` (`Pager`, `MMap`, `ReaderTable`,
  `FileChannel`, `WriterThread` boxes) is documented and genuinely needs the escape hatch; none could be
  plain `Sendable`. No actors; no `nonisolated` misuse.
- **Float `==` sites are intentional** (exact-zero normalization, round-trip/representability checks).

### 3.2 Done & committed during the health engagement

| ID | Change | Where | Commit |
|---|---|---|---|
| **C3** | `ByteCodec.loadBE64` (single byte-swapped load); replaced two manual BE shift-loops in `KeyCodec.readBE` / `rowid(fromSuffixOf:)` | `ByteCodec.swift`, `KeyCodec.swift` | `8ddcc9a` |
| **R2** | Always-on snapshot **`pageCount` guard** in `CommittedResolver.resolvePage` + `TxnContext.resolvePage` — a corrupt in-page pointer into mapped-but-uncommitted (zeroed) space now throws `DBError.corruptPage` instead of silently reading it | `TxnContext.swift`, `Integrity.swift`, `Database.swift` | `6ccde9a` |
| **R1** | Opt-in **`DatabaseOptions.verifyChecksumsOnRead`** (default off) — checksum-verifies committed pages as they fault in; catches the full corruption class for untrusted files without regressing the hot path | `Database.swift`, `TxnContext.swift` | `6ccde9a` |
| **R1/R2 tests** | `IntegrityGuardTests` — out-of-range page rejected; flipped free-space byte silent without verify, caught with it | `Tests/.../IntegrityGuardTests.swift` | `6ccde9a` |
| **R3** | Thread-safe `strerror_r` in `DBError.description` (was non-reentrant `strerror`, shared static buffer) | `Errors.swift` | `18e5cb7` |
| **S3 (JSON)** | 8 direct unit tests for the no-Foundation JSON parser (surrogate pairs, lone-surrogate→U+FFFD, path extraction, malformed handling, render round-trip) | `Tests/.../SQLJSONTests.swift` | `509fa33` |
| **CI** | Fixed invalid `--skip-tag soak` flag; later evolved to genuinely run soak-tagged tests | `.github/workflows/ci.yml` | folded / `86d9bde` |

**Owner robustness/consistency (same themes):** `7847e7c` (catchable `DBError` for over-long table/FTS
names instead of trapping), `991020c` (optional-chaining over nil-check-then-force-unwrap).
**Finding corrected & dropped — C2:** `UInt16(exactly: v)!` adds nothing; Swift's `UInt16(value)`
narrowing initializer **already traps** on out-of-range (the *wrapping* form is
`UInt16(truncatingIfNeeded:)`, which the code does not use). Slotted-page writes already fail closed.

---

## 4. Performance status — unified & complete

### 4.1 Goal, philosophy & the seven criteria

**Goal.** Make ADSQL beat system SQLite on *every* SQL workload, with **zero loss** of correctness,
durability, or concurrency guarantees.

**Philosophy (owner directive).** Do **not** replace code in place. For each performance dimension,
implement *every* alternative strategy **beside** the existing, verified one; make them **configurable
and tunable**; **benchmark all of them against seven criteria**; and **remove nothing** until a strategy
demonstrably wins on all seven. Defaults stay at today's behavior until data justifies a flip. The
tree-walk evaluator and the nested-loop join likely remain *permanently* as correctness references and
fallbacks. *(This session amends the rule only for **pure-win** waste — see §6 / RFC 0009 waste policy.)*

| criterion | enforcement mechanism |
|---|---|
| **accuracy** | every strategy's results identical to each other AND to the CSQLite oracle (`SQLiteMirror`); strategy-matrix differential tests |
| **performance** | `ADSQLBench` latency percentiles (`LatencyHistogram`) + throughput (`formatRate`), per strategy, vs the SQLite arm |
| **concurrency** | `swift test --sanitize=thread` on every changed row/scan/write path |
| **parallelism** | the multi-reader `concurrent` scenario (readerCounts `[1,4,8,12,16]`) per strategy → scalability curve |
| **reliability** | crash-injection (`SimulatedDisk` + `CommitRecoveryTests`: `barrierProfileSweepEveryCutGroup`, `randomizedCrashStorm`) per write/insert strategy |
| **consistency** | snapshot isolation holds identically under every strategy (multi-reader-during-write differential) |
| **integrity** | `Integrity.deepCheck` (page liveness + index⇄row bijection + `index.handle.count == table.handle.count`) + byte-identical canonical table dumps across insert strategies |

**Three pluggable dimensions** (selected by `ExecutionOptions`, per-database via `DatabaseOptions.execution`
or per-statement via `Statement.setExecutionOptions`):

| dimension | reference (default) | alternatives | status |
|---|---|---|---|
| **Evaluator** | `treeWalk` | `compiledClosures` ✅, `vdbe` (todo) | enum cases declared in `ExecutionOptions.swift` |
| **Join** | `nestedLoop` | `hash` ✅, `merge` (todo), `auto` cost-based (todo) | `runInnerHashJoin` exists; merge/auto fall back |
| **Insert** | `standard` | `hoisted` (todo), `appendCursor` (todo) | both fall back today |

### 4.2 Why SQLite is faster where it is (profiling)

Profiled with `/usr/bin/sample` (1 ms) on `ADSQLBench sql`, attributing self-time to symbols.

**SQLite's hot stack is lean:** `sqlite3VdbeExec` (one flat bytecode loop) +
`sqlite3BtreeTableMoveto`/`IndexMoveto` + `memcmp`/`vdbeRecordCompareString` on raw page bytes. **No
malloc, no refcounting, no String materialization** in the leaders; `guarded_pwrite_np` (insert I/O) tops it.

**ADSQL's hot stack is dominated by language-runtime overhead SQLite never pays** (search+insert profile):
- `swift_beginAccess`+`endAccess` ≈ **1070** — dynamic exclusivity checks on **class-property mutation
  inside per-row loops** (`Accumulator.rows/sortKeys/seenRowids`, `RowSlot.cache/offsets`,
  `RowContext.nullExtended`).
- ARC churn ≈ **2300+** (`swift_release/retain/isUniquelyReferenced/bridgeObject*/allocObject/
  deallocClassInstance/arrayDestroy`) — `Value` boxing String/[UInt8], `[Value]`/`[[Value]]` CoW, `GroupKey`.
- malloc family ≈ **900**; `String(decoding:)` per TEXT read (`RecordCodec.decodeOne`);
  `SQLCompare.compareUTF8` (byte-iterator compare, not `memcmp`).
- `Node.search` (513) — B-tree descent; `SQLEval.evaluate` (552) — the tree-walk.

**Per-scenario attribution (CPU share):** JOIN > DISTINCT > SEARCH. Root causes (DISTINCT/SEARCH now
fixed): DISTINCT materialized-then-deduped 200k rows (now index-ordered adjacent dedup); SEARCH's
`(fw,kind)` index doesn't cover `key`, so each match descended to the table + String-decoded (now
zero-copy top-N); JOIN per outer row did an index→table descent + `b.key` decode + redundant ON re-check
(now existence probe; residual = per-probe `KeyCodec.encode` + `a.key` String decode + the inherent seek).

### 4.3 SQL scorecard (vs system SQLite, 200k rows; reports' numbers + Phase-0 re-baseline)

| scenario | ADSQL | SQLite | ratio | notes |
|---|---|---|---|---|
| cold open → first get | leads | — | ~5–13× | pre-existing |
| point get / rowid get (p50) | ~0.8–4 µs | ~2–5 µs | ~3× | pre-existing |
| raw KV scan | ~4.9 GB/s | ~4.0 GB/s | ~1.2× | pre-existing |
| 16 concurrent readers | ~1.07 M/s | ~0.47 M/s | ~2.3× | pre-existing |
| **DISTINCT** | **4.3 ms** | 9.9 ms | **2.3× faster** ✅ | was 0.08× |
| **SEARCH** (p99) | **~5.4 ms** | ~5.3 ms | **≈ parity** ✅ | was 0.44×; p50 bimodal — use p99 |
| **JOIN** (COUNT(*) self-join) | **164 ms** | 42.8 ms | **0.26×** ⚠️ | was 0.12× |
| **INSERT** (batch, 3 idx) | **161 k/s** | 209 k/s | **0.77×** ⚠️ | was 0.70× |

**Caveats:** absolute numbers vary with thermal/load — always compare **back-to-back in one session**;
trust ratios over absolutes. SEARCH **p50 is bimodal** (only 12 of 24 `(framework,kind)` combos
populated; a random query hits an empty combo ~50% of the time → ~20µs vs ~5ms) — use **p99**. **Only
JOIN and INSERT still lose.**

**Phase-0 re-baseline** (HEAD `2d5f347`/`e147bde`, 200k rows, `--point-gets 1000`, this machine,
2026-06-14, ADSQL vs system SQLite): insert **131.9k/s vs 178.3k/s (0.74×)** ⚠️ · key-select p50 5.0µs vs
5.1µs (≈) · search p99 **5.89 ms vs 5.72 ms (≈ parity)** ✅ · distinct p50 **5.42 ms vs 11.0 ms (2.0×
faster)** ✅ · join p50 **183 ms vs 48 ms (0.26×)** ⚠️. **Confirms the scorecard:** JOIN (0.26×, exact match)
and INSERT (0.74×) are the two losing paths; DISTINCT wins, SEARCH ≈ parity. The SQL JOIN/INSERT hot paths
are unchanged since baseline, so these are directly comparable. *(The FTS arm is not re-measured here — it
is a moving target under active F6 iteration; RFC 0008 carries the live FTS numbers.)*

### 4.4 FTS scorecard (NEW — absent from the perf report; from RFC 0008 F6 trail, 2k docs vs SQLite FTS5)

The FTS work (M5, RFC 0007) transformed FTS perf across F6c→F6n (F6l/F6m/F6n landed concurrently during
this consolidation, further widening the ranked lead). The figures below are the F6k baseline; **RFC 0008
has the live per-slice numbers**. Standing at consolidation:

| FTS axis | ADSQL | SQLite FTS5 | standing | how |
|---|---|---|---|---|
| **ranked top-k** (`ORDER BY bm25 LIMIT 20`) p50 | **187 µs** | 426 µs | **~2.3× faster** ✅ | F6c block-max WAND → F6i prepared score-all → F6j incremental WAND payload → F6k zero-copy sum-only `docLength` |
| ranked top-k p99 / p99.9 | 629 µs / 709 µs | 776 µs / 839 µs | **faster** ✅ | per-doc re-decode + malloc churn eliminated |
| **MATCH** (membership) p50 | ~µs-scale | — | **~3.3× slower** ⚠️ | F6e membership fast path; residual is the **general SELECT row path** (§5.7), not FTS |
| **index build** | linear, ~14k rows/s (batched) | ~100k rows/s | **~7.4× slower** ⚠️ | F6d block-per-key (O(n²)→O(n)) + F6f txn-scoped memtable; constant factor — needs raw-segment postings (B+tree puts vs FTS5 segment blobs) |

Combined ranked wins F6i+F6j+F6k: **p50 1556→187µs (~8.3×), p99 104ms→629µs (~165×).** The FTS bench
(`ADSQLBench/FTSScenario.swift`, F6b) measures all three axes vs real SQLite FTS5 — but only the one
`documents_fts` shape (§5.3 — expansion target).

### 4.5 What shipped (committed `8ddcc9a`) — SQL perf mechanisms

Targeted perf fixes (now the default path), all validated (full suite + differential/property suites
green; `-strict-memory-safety` clean; TSan clean on changed paths; crash-injection green):

| fix | mechanism | files | result |
|---|---|---|---|
| DISTINCT streaming dedup | dedup into a `Set<GroupKey>` during the scan (kept-set, not 200k rows) | `Executor.swift` `Accumulator` | memory-bounded |
| **DISTINCT index-ordered** | scan a covering index in key order; adjacent-dedup by raw key-prefix bytes; decode distinct values from the key (no table descent) via new `KeyCodec.decode` | `Executor.swift` `runDistinctIndex`, `KeyCodec.decode`, `Plan.swift` `distinctIndexName` | 123→**4.3 ms**, beats SQLite |
| referenced-cols + COUNT(*) guard | bind-time `(table,column)` reference set; skip materializing a group representative no output/HAVING/ORDER BY reads | `Plan.swift`, `Executor.swift` `runAggregated` | enables join existence |
| **JOIN existence probe** | `fastExistence`: UNIQUE-index full-key equality → single seek (A4 seek+`isValid`+prefix-`elementsEqual`) with a zero-copy probe key from the outer column's page bytes; no descent, no ON re-check, no materialization | `Executor.swift` `fastExistence`/`appendProbeField`, `RowSlot.withTextBytes`, `KeyCodec.append*` | 395→164 ms |
| **SEARCH zero-copy top-N** | single-text-column ORDER BY: compare the candidate's sort-key bytes in place vs the worst kept entry; materialize only on the cut (B4 NULL-first+DESC) | `Executor.swift` `Accumulator.fastDropsCandidate`, `Eval.swift` raw `compareUTF8`/`NoCase` | ≈ parity |
| INSERT buffer reuse | reuse per-txn record/index encode scratch buffers | `DML.swift`, `TxnContext.swift`, `RecordCodec.encode(into:)`, `KeyCodec` | +9% |

**Maturity-program foundation (alternatives selectable; defaults unchanged):**
- **Phase 0 — config + seam.** `ExecutionOptions` (Sendable value, snapshot-copied per execution → no
  shared mutable state, MVCC untouched). `DatabaseOptions.execution` + `Statement.setExecutionOptions`.
  Plan cache keyed on `(catalogVersion, planningTag)` so a plan bound under one join strategy is never
  reused under another.
- **Phase 2 — compiled-closure evaluator** (`CompiledEval.compile`). Lowers each bound `SQLExpr` to a
  typed-throws closure tree **once**, reading slots straight from `RowContext` (no env closure) and
  **baking affinity + collation at bind time**. Mirrors `SQLEval.evaluate` exactly; **returns nil →
  tree-walk fallback** for unsupported nodes. Wired to the single-table scan path. Measured **distinct
  ~23%, search ~9%** faster on covered scans. Validated `treeWalk ≡ compiled ≡ SQLite`
  (`SQLStrategyMatrixTests`, 13 cases).
- **Phase 3a — hash join** (`runInnerHashJoin`). 2-table INNER equi-join: build a
  `[GroupKey:[(rowid,values)]]` hash of the inner, probe the outer; produces the same composite
  `RowContext` state. Self-extracts equi-keys from the bound ON; restricted to same-class/same-collation
  `column=column` keys; non-equi conjuncts re-checked; NULL probe keys match nothing; memory-budget
  fallback. Validated `nestedLoop ≡ hash ≡ SQLite` (`SQLHashJoinTests`, 8 cases).
- Bench flags `--eval`, `--join`, `--point-gets`; seeded strategy-matrix differential harness.

### 4.6 Critical empirical findings (these dictate the roadmap)

1. **Hash join is the WRONG tool for the symmetric self-join.** Measured **716 ms vs nested-loop 186 ms**
   — it materializes all 200k inner rows. Hash wins on **unbalanced** joins (small build side); it must
   never be chosen for a large symmetric join. ⇒ **the cost model is mandatory.**
2. **The JOIN-benchmark winner is the MERGE join.** Both sides share the sorted `u_documents_key`, so a
   single O(N) lock-step merge — byte-compare keys, no materialization, no per-probe descent — can
   **beat** SQLite. Not yet built.
3. **A hash semi-join** (inner `innerExistenceOnly`, e.g. COUNT(*): build key *counts*, don't materialize)
   makes hash competitive even on the symmetric benchmark.
4. **Compiled-evaluator's projected 3–5× needs broader coverage** — today only the single-table scan
   path. Big wins are on comparison-heavy table-scan WHEREs (affinity baking) and the join ON / aggregate paths.
5. **INSERT's safe wins are workload-narrow.** State-copy/index-sort/cursor-reuse matter on *many-index*
   DBs (~13% there); on the apple-docs shape (1 table, 3 indexes) they're a few %. The real lever is the
   crash-critical `appendCursor` for sequential-rowid appends.

---

## 5. New findings (whole-tree pass at HEAD `f0e0e5b`) + the waste catalog

### 5.1 Structure — six god-files now (reports flagged three)

Current line counts (>600 flagged): `SQL/Executor.swift` **1569**, `SQL/Parser.swift` **1148**,
`SQL/Plan.swift` **975**, `SQL/Writer.swift` **686**, `Relation/Relation.swift` **634**,
`Relation/DML.swift` **601**. The reports' S2 named only the first three; Writer/Relation/DML have since
crossed the target. (FTS files are cohesive and isolated — see §5.9.)

### 5.2 — (FTS perf delta) — see §4.4. The perf report omits FTS entirely; 0003 now carries it.

### 5.3 FTS5/bm25 bench EXISTS but is narrow (expansion target)

`ADSQLBench/FTSScenario.swift` (F6b) already benches **build + MATCH + ranked-bm25 vs real SQLite FTS5**
and is opt-in via the `fts` scenario. Gaps to close (RFC 0009 Phase 1): only the **1** self-contained
`documents_fts` shape (the other three apple-docs shapes — `documents_trigram` external/trigram,
`documents_body_fts` contentless, `sf_symbols_fts` prefix/`columnsize=0` — are parity-tested in
`FTSParityTests` but **not benched**); a **single** bm25 weight set (no **bm25f** variation); no
`snippet()`/`highlight()`; no update/delete **churn** (the ai/ad/au trigger-sync path); no
**concurrent-FTS-reader** arm; `rowCap`=8k; and `fts` is **excluded from the default matrix**.
*(The owner flagged FTS5/bm25 as "not covered" — the accurate statement is "covered, but narrow.")*

### 5.4 INSERT waste — verified at HEAD (`Relation/DML.swift`)

- `:363–365` rebuilds **and sorts** the owned-index list **per row** (`.filter{…}.sorted{…}`);
  `:405` re-sorts `state.indexRecords.keys.sorted()` **per row** — two per-row allocations + sorts, plus
  repeated `state.indexRecords[indexName]!` dictionary lookups inside the loop.
- `allocateRowid` `:270–283` — for plain (non-AUTOINCREMENT) rowid tables, probes
  `cursor.move(to:.last)` **every insert** (O(depth) mmap descent) to compute `max(rowid)+1`. → the
  `appendCursor` lever (Phase 5).
- `uniqueConflict` `:206/:208` — allocates `indexColumnValues` (a `.map`) + `KeyCodec.encode` per unique
  index per row.
- `insertCore` `:336` — copies the `RelationState` struct and reassigns `ctx.relation` per row
  (dictionary CoW). → hoisted in-place mutation (Phase 3).
- `KeyCodec.rowKey(rowid)` allocates a fresh `[UInt8]` per call (`:360`, `:401`). → scratch reuse / `InlineArray`.

### 5.5 TEXT materialization — per-read String allocation

`RecordCodec.decodeOne` `:236` does `String(decoding: slice, as: UTF8.self)` per TEXT cell;
`materializeRow` (`DML.swift:118`) decodes the **whole** row to `[Value]` on every update/delete/backfill
(`:489`, `:437`, `:585`). The zero-copy `withText`/`withBlob` path (`RecordCodec.swift:123–185`) is not
used on these write paths. → opportunistic zero-copy reads where the full `[Value]` isn't needed (Phase 3/6).

### 5.6 The strategy seam is already declared (scaffolding exists)

`SQL/ExecutionOptions.swift` declares `Join.{nestedLoop,hash,merge,auto}`,
`Insert.{standard,hoisted,appendCursor}`, `Evaluator.{treeWalk,compiledClosures,vdbe}`, the
`hashJoinMemoryBudgetBytes` knob, and `planningTag`. Only `hash`/`compiledClosures` are implemented;
`merge`/`auto`/`hoisted`/`appendCursor`/`vdbe` currently fall back. Bench flags `--join`/`--eval` already
route them. So the perf work is **filling in declared cases**, not new plumbing.

### 5.7 Unifying bottleneck — the per-row row-materialization path

RFC 0008 F6l established the residual FTS-MATCH gap is **not FTS-specific**: it is
`SelectExecutor.Accumulator.consume`→`project()` building a `[Value]` per matched row + `context.load` +
ARC/exclusivity — **the same per-row `[Value]`/ARC/exclusivity waste** §4.2 fingered for JOIN/SEARCH. **One
lever** — a value-light row path (wider `CompiledEval` + the VDBE register machine + local-`var`
accumulation that the optimizer proves exclusive) — closes JOIN, SEARCH **and** FTS-MATCH together (Phase 6).

### 5.8 Memory-safety & idiom of the new FTS F6 code

- **Sound.** The frame-of-reference bit-packed docid codec (`FTS/Postings.swift:203–297`) is carefully
  bounded: varint header reads guarded; `byteCount=(totalBits+7)/8` with `offset+byteCount<=bytes.count`
  before the packed region; bit-field window load checks `b<bytes.count`; `gapBits<=64`; product
  ≤ 8192 bits (no overflow). Prefix-sum uses wrapping `&+` matching the encoder. The zero-copy `docLength`
  (`FTS/FTSIndex.swift:318–338`) reads via `BTree.withValueBytes` (scope-bounded borrow) and decodes only
  the leading field-length varints — a correctness + perf win.
- **Re-verified at HEAD `2d5f347` — NO ACTION needed; the three flagged sites are all justified** (the
  initial scan over-flagged them): `Postings.swift:62–63` `block.first!`/`.last!` are provably non-empty
  (the `while index < postings.count` loop invariant; internal encoder data, **not** an untrusted
  boundary); `FTS/FTSIndex.swift` `unsafe Varint.read(raw,…)` is **required**, not redundant (the F6k/F6n
  zero-copy `docLength` reads a raw `UnsafeRawBufferPointer`); `FTS/Trigram.swift:60`
  `Unicode.Scalar(scalar.value+0x20)!` is guarded by `(0x41...0x5A).contains` on the same line. Adding
  `guard…throw`s here would defend can't-happen cases on trusted internal data — churn, not safety.

### 5.9 S4 reclassified — FTS-write-bleed is now largely localized

`Writer`/`DML`/`Relation` call only `FTSIndex`/`Tokenizer` **public APIs**; the FTS encoder/scorer/WAND
internals are not exposed to generic DML. Reclassify the reports' S4 "cohesion smell" from a refactor to
a **verify + minor tidy** (move any residual FTS-write section beside `FTS/` while splitting `Writer.swift`
in Phase 2).

### 5.10 Waste catalog — prioritized

| # | waste | location | fix / phase | est. impact |
|---|---|---|---|---|
| W1 | per-row owned-index filter+sort ×2 | `DML.swift:363–365,405` | hoisted InsertPlan (P3) | INSERT, scales with #indexes |
| W2 | per-insert `move(to:.last)` rowid probe | `DML.swift:270–283` | appendCursor (P5) | INSERT (sequential) |
| W3 | per-row `RelationState` struct/dict CoW | `DML.swift:336,417` | in-place mutate (P3) | INSERT |
| W4 | `String(decoding:)` per TEXT read; whole-row `materializeRow` | `RecordCodec.swift:236`, `DML.swift:118` | zero-copy reads (P3/P6) | UPDATE/DELETE/scan |
| W5 | per-row `[Value]` project + ARC + exclusivity | `Executor` `Accumulator.consume`/`project` | compiled-eval/VDBE/local-vars (P6) | JOIN, SEARCH, FTS-MATCH (§5.7) |
| W6 | per-probe `KeyCodec.encode` + `a.key` String decode + index seek | JOIN residual | merge join / cost model (P4) | JOIN |
| W7 | `rowKey` per-call alloc; `uniqueConflict` map+encode | `DML.swift:360,401,206,208` | scratch reuse / `InlineArray` (P3) | INSERT |
| W8 | FTS index build constant-factor vs FTS5 segments | `FTSIndex` | raw-segment postings (post-P5, F6 follow-on) | FTS build |

*(Phase-0 `/usr/bin/sample` profiles append confirmed self-time attributions here.)*

---

## 6. Remaining work — designs (the execution program lives in RFC 0009)

### 6.1 Quality / health

- **S2 — split the six god-files** (pure code motion, zero behavior change, one commit per file):
  `Executor.swift` → `JoinExecutor.swift`, `AggregateExecutor.swift`, `ResultPipeline.swift`
  (DISTINCT/ORDER BY/LIMIT/compounds), `RowSourceExecutor.swift`/`ProbeEval.swift`; `Plan.swift` → extract
  `enum Binder` → `Binder.swift`; `Parser.swift` → `Parser+DDL.swift`, `Parser+Expr.swift`; bring
  `Writer.swift`/`Relation.swift`/`DML.swift` under ~600 lines. Target: no `SQL/` or `Relation/` file > ~600 lines.
- **S1 — tighten the public surface:** demote storage internals `public` → **`package`** (the build passes
  `-package-name adsql`; `Tests/ADSQLTestSupport` is a regular non-`@testable` target that needs
  `package`, not `internal`). Keep public exactly: `Database`, `DatabaseOptions`, `ReadTxn`, `WriteTxn`,
  `Statement`, `SQLParameters`, `SQLRow`, `SQLColumnHeader`, `RunResult`, `SQLTransaction`, `DBError`,
  `Value`/`ColumnType`/`Collation`, `Relation/Definitions.swift`, `IntegrityReport` + `verifyIntegrity`,
  `ExecutionOptions`, `DurabilityProfile`, `Format.formatVersion`. Demote `Pager`, `BTree`, `MMap`,
  `PageBuf`, `Committer`/`Recovery`, `Cursor`, `NodeBuilder`, `Page`, `Overflow`/`OverflowPager`,
  `FreeList`, `FileChannel`/`StorageChannel`, `Meta`/`TreeHandle`, `PageType`, `Varint`, `XXH64`,
  `TxnContext`/`CommittedResolver`/`PageSource`/`PageResolver`/`PageAllocator`, `RecordCodec`, `KeyCodec`,
  `RelationState`, `SchemaCache`, `Row`/`RowView`/`RowCursor`, `CivilTime`, and the FTS internals — unless
  a public custom-tokenizer plug-in API is intended. AST/lexer are a judgment call (likely `package`).
- **C — strong ID types (SCOPED, not a mechanical sweep):** zero-cost `PageNumber`/`Generation`
  `RawRepresentable` wrappers only at the highest-signal boundaries (`Meta` fields, `PageAllocator`,
  free-list `harvest`/`serialize`/`reclaimLimit`). ~200 edits if pursued fully — adopt only where a
  `gen`-vs-`pageNo` swap is plausible; **drop if it adds conversion noise without catching anything.**
- **S3-remainder (optional):** direct unit tests for `SQLFunctions` numeric coercion/affinity/`realToText`
  edges and tricky `Pragma` branches (end-to-end covered; `CompiledEval` is locked by the strategy matrix).
- **S4 (verify + tidy):** §5.9 — move any residual FTS-write section beside `FTS/`.
- **Safe-type micro-fixes:** §5.8.

### 6.2 Performance — detailed designs

**JOIN (highest value):**
- **(a) Merge join** — `MergeJoin.swift`, dispatched from `forEachFilteredRow` when `execution.join==.merge`
  and eligible (2-table equi-join, both sides expose a sorted index on the join key in the same order &
  collation). Lock-step: byte-compare key-prefixes (A4 minus the rowid suffix), advance the smaller; on
  equality gather the dup run on each side and emit the cross-product. **Existence/COUNT(*) fast path:**
  inner `innerExistenceOnly` → no table descent, multiply run lengths into the match count. Referenced
  columns: descend by rowid per emitted row or read a covering index value. NULL runs never match.
- **(b) Cost model `.auto`** — `Planner.planJoin` + `BoundJoin.driver`. Estimate INLJ ≈ `M·logN`, hash ≈
  `M+N` (build smaller side, only if it fits the budget), merge ≈ `M+N` (only if both sides sorted) using
  `TreeHandle.count` + equality selectivity (unique ⇒ ≤1 inner match; else `N/distinct`); pick the min;
  tie → `nestedLoop`. `.nestedLoop/.hash/.merge` force a driver. `planningTag` already keys the plan cache.
  Superset-preserving (leaf re-applies ON/WHERE), so a wrong estimate only changes *speed*, never results.
- **(c) Hash semi-join** — in `runInnerHashJoin`, when `join.innerExistenceOnly && onResidual==nil`: build
  `[GroupKey:Int]` counts, probe the outer, emit `count` times — no inner materialization (needs an indexed fixture).

**INSERT:**
- **(a) `hoisted`** (safe; no COW/split change) — a `Relation.insertBatch(…, plan: InsertPlan)` where
  `InsertPlan` precomputes once per statement the table/state fetch, the sorted owned-index & unique-index
  lists (today rebuilt every row, §5.4), and reusable conflict cursors. Mutate `ctx.relation` **in place**.
  Keep `insertCore` as the single-row reference. Differential vs `standard` (results + RETURNING +
  byte-identical dump) + deep integrity + crash-injection per strategy.
- **(b) `appendCursor`** (crash-critical; the real lever) — `AppendCursor.swift` + a per-tree warm cache on
  `TxnContext` (writer-confined, not Sendable): the rightmost leaf (pageNo + dirty `PageBuf`) + its max key
  + the tree's `rootPage` (staleness). For strictly-ascending rowid inserts: if the new key sorts after the
  cached max **and fits the rightmost leaf without a split**, append in place + bump `count`. **Any** of
  {non-ascending, would-split, stale} falls through to the proven `BTree.put`. Invalidate on first
  non-append mutation, request rollback (`rollbackRequestScope`), DDL. Never produces a structurally
  different tree. **Hard gate:** crash-injection (`barrierProfileSweepEveryCutGroup`, `randomizedCrashStorm`),
  especially mid-split; drop if not spotless.

**EVALUATOR (widen every lead; closes §5.7 across JOIN/SEARCH/MATCH):**
- Extend `CompiledEval` to the join ON (`descend`), the residual/WHERE on filtered table scans, aggregate
  finalization (compile once against a swappable "current group" holder captured by reference), and
  `.like`/`.inList`/`.function`.
- **Phase 4 — VDBE register machine** (`SQL/VDBE/`): a flat opcode loop over a register file, the structural
  end-state matching `sqlite3VdbeExec`. `Opcode.swift` (~20–25 ops), `Program.swift` (instructions +
  register `[Value]` + a `Compiler` lowering `BoundSelect`), `Machine.swift` (`VDBEEvaluator: RowEvaluator`,
  reads columns through `RowContext`/`RowSlot` to reuse zero-copy decode + the `@safe` span — stays
  strict-memory-safe; registers are `[Value]`, no raw pointers). Ships incrementally (compiler nil →
  tree-walk fallback). Single-table first, then joins/aggregates. Multi-week.

**Cross-cutting infrastructure:**
- **Multi-criteria bench harness** — `ADSQLBench/StrategyBench.swift` + `--strategy-matrix`: per scenario ×
  strategy report all seven criteria (perf percentiles+throughput; concurrency/parallelism via `concurrent`;
  reliability via crash-injection pass/fail; integrity via `deepCheck` + canonical dumps). Keep the CSQLite
  arm as the external baseline. **This is the gate that lets code be retired.**
- **FTS bench expansion** — §5.3.
- **Grow the differential matrix** (`SQLStrategyMatrixTests`) as each strategy lands — every combo of
  `Evaluator × Join × Insert` must agree with each other and SQLite and leave byte-identical DB state.

**Selection & retirement (the ONLY place code is removed):** flip a default per dimension **only after** a
strategy wins on **all seven criteria** (candidates: `join=.auto`; evaluator→compiled/vdbe;
insert→hoisted/appendCursor). Keep a superseded path selectable one release (bisection). Update `ROADMAP.md`
+ `docs/rfcs/` + this review.

---

## 7. Apple-native safe-type adoption + latent ledger

### 7.1 Safe-type adoption — status

| Type / idiom | Status | Notes |
|---|---|---|
| Typed throws `throws(DBError)` | ✅ done | exact below the façade |
| `~Copyable` cursors/txns; `~Escapable` + `RawSpan` page views | ✅ done | `Cursor`, `ReadTxn`/`WriteTxn`, `RowView`, `ValueRef` |
| `Synchronization` `Mutex`/`Atomic` (explicit orderings) | ✅ done | in-process state, double-close guard |
| Thread-safe libc (`strerror_r`) | ✅ done (R3) | `CivilTime` does its own math, not `localtime` |
| `loadBE64`/`loadLE*` unaligned loads | ✅ done (C3) | BE now consistent with LE |
| Strong ID typedefs (`PageNumber`/`Generation`) | ⏳ C (scoped) | bare `UInt64`/`UInt16` today |
| `Duration`/`ContinuousClock` | ⏳ bench only | kernel has **zero** time APIs (correct); `ADSQLBench` `Stats.nowNanos`/deadline use raw `UInt64` |
| `InlineArray` (fixed-size) | ▫ marginal→W7 | `KeyCodec.rowKey`/`FreeList.entryKey` tiny `[UInt8]`; `writeRowKey(into:)` already allocation-free |
| `os.Logger`/`OSSignposter`, `import System`, Accelerate, Compression | ▫ RFC 0005 | out of scope here (may ride Phase 1 if it pays for itself) |

### 7.2 Latent ledger (accepted-as-interim — tracked, **not** bugs)

- **`RowSlot` / `LeafCell` / `LeafValue` are `@safe`-by-assertion** (temporal, CWE-416/562 class): they
  store a scope-bounded borrowed `UnsafeRawBufferPointer` and are consumed synchronously, but the compiler
  does not *enforce* non-escape. The enforced fix is the full `~Escapable` + `RawSpan` threading through the
  evaluator (`SQLEvalEnv.column` closure) and the node primitives (`NodeBuilder.leafCell` has no
  lifetime-bearing owner to bind to) — disproportionate today; each carries a precise `// SAFETY:` note.
  (Review 0001 F1/F2.)
- **`PageBuf` `MutableRawSpan` / `withMutableBytes` migration deferred** (~60 in-module mutator sites; the
  naked `raw` pointer is already `internal`). (Review 0001 F4.)
- **Page-internal cell-field trust (residual of R1):** `Node.leafCell`/`branchKey`/`nodeKey` read
  `keyLen`/`valueLen`/`slotOffset` and `rebasing:` slice; on a corrupt-but-in-`pageCount` page these rely
  on the `UnsafeRawBufferPointer` subscript trapping in `-O` (fail-closed) unless `verifyChecksumsOnRead`
  is enabled. R2 closed the out-of-range-pointer hole; full structural validation on every read was
  deliberately **not** added (perf). Threat model: trusted-file-by-default, `verifyChecksumsOnRead` for untrusted.

---

## 8. Correctness landmines (honor every one — carried from the perf report)

- **A4 — index key layout.** Stored index keys are `encode(columns) ‖ 8-byte rowid`. A bare
  `Cursor.seek(prefix)` returns `exact==false` even when a matching row exists. Existence must use **seek +
  `isValid` + prefix-`elementsEqual`** (the `Relation.firstRowid` shape). `KeyCodec.decode` requires the
  caller to have **stripped the rowid suffix** (a terminator `00` followed by a suffix byte `FF` would be
  misread as an escaped null).
- **B4 — DESC + NULL.** The descending flip applies to the **final** comparison only; NULL-sorts-first
  (ASC) must be preserved exactly as `orderCompare` does.
- **`GroupKey` equality vs SQL `=`.** `GroupKey` canonicalizes numeric classes (1 ≡ 1.0) and folds NOCASE;
  it equals SQL `=` **only for same-class/same-collation** operands. Hash/merge join keys are therefore
  restricted to same-class/same-collation `column=column` (no affinity coercion ⇒ no false negatives); the
  non-equi residual ON is re-checked at each match. A mismatched type/collation join falls back to nested-loop.
- **`KeyCodec.decode` NOCASE lossiness.** NOCASE text is folded at encode time, so decode yields the
  **folded** bytes, not the original. Index-ordered DISTINCT **excludes NOCASE-text columns** (binder gate);
  INTEGER/REAL/BINARY-text/BLOB/NULL round-trip losslessly.
- **Affinity baking.** The compiled evaluator bakes schema-fixed affinities/collation at compile time but
  applies *value* coercion at runtime (the runtime value class is still checked) — semantically identical
  to `SQLEval`, only the timing changes.
- **Type-boundary gate.** Zero-copy probe-key/hash-key paths engage only when the outer column class == the
  index/inner class; otherwise fall back to the `Value`-coercing path (int↔real, text↔int affinity, proven-empty).
- **Empty-span safety.** An existence-only inner slot is loaded with an empty span; safe *because* the inner
  is unreferenced (`value(at:)` never called; `RowSlot` decodes lazily).
- **NULL join keys.** `NULL = NULL` is unknown → no match. Hash/merge skip NULL probe keys; build-side NULL
  entries are never matched.
- **Exclusivity.** Class-property mutation in per-row loops triggers `swift_beginAccess` (~1000 samples).
  Mitigate by accumulating into **local `var`s** the optimizer can prove exclusive — **never** by disabling
  exclusivity enforcement (that drops a memory-safety check).

---

## 9. Risk register (carried from the perf report)

| risk | severity | mitigation |
|---|---|---|
| `appendCursor` vs split / group-commit undo | **HIGH** | defer every split to `BTree.put`; invalidate warm cache on rollback; crash-injection mid-split |
| evaluator semantic drift (compiled/VDBE affinity/collation/3VL) | **HIGH** | mirror `SQLEval` exactly; full-corpus differential matrix; nil → tree-walk fallback |
| hash-join memory blowup | MED | budget knob (`hashJoinMemoryBudgetBytes`) + nested-loop fallback; build smaller side |
| merge-join dup-run / collation | MED | restrict to provably-sorted-both-sides; differential fuzzing |
| plan-cache reuse across planning-relevant options | MED | `planningTag` in the cache key (done) |
| concurrency regressions | LOW | `ExecutionOptions` is read-only `Sendable` data snapshot-copied per execution; no new shared mutable state; TSan every change |
| god-file split introduces behavior change | LOW | pure code motion; diff reviewed as move-only; tests + TSan green |
| `public`→`package` breaks a hidden external consumer | LOW (semver) | audit found none above the kernel; verify all products + test targets build |

---

## 10. Measurement methodology (honor for every perf claim)

- **Bench:** `swift run -c release ADSQLBench sql --engine adsql|sqlite --point-gets N --eval
  treeWalk|compiled|vdbe --join nestedLoop|hash|merge|auto`. `--point-gets` controls search/key iteration
  count (default 30k → ~260 s; use a few hundred/thousand for fast loops). FTS: the opt-in `fts` scenario.
- **SEARCH p50 is bimodal — use p99** (§4.3).
- **Profiling:** `/usr/bin/sample <pid> <secs> 1 -file out.txt -mayDie`; attribute via `SQLScenario.swift`
  call-site line numbers and the "Sort by top of stack" self-time section. Use the **real** sampler, not a
  homebrew shim (F6i overturned an F6g guess this way).
- **Machine variance is real** (thermal/background shift absolutes ~2–3×). Compare strategies **back-to-back
  in one session**; trust ratios over absolutes.
- **Read the test/build log's own summary line** (`Test run with N tests … passed`, `error:`), never the
  wrapper exit code — a trailing `tail`/`echo`/`grep -c` (which exits 1 on zero matches) masks the real result.

---

## 11. Quick reference (file anchors)

**Integrity:** `Page.swift:100/105` (checksum), `MetaPage.swift:145` (`recover`), `:56` (`reclaimLimit`),
`Committer.swift:18` (`commit`), `ReaderTable.swift:126/133` (horizon), `adcatomics.h:12/17` (atomics).
Read guards (R1/R2): `TxnContext.swift` (`resolvePage`, `CommittedResolver`), `Database.swift`
(`verifyChecksumsOnRead`, `read`).
**Config/dispatch:** `SQL/ExecutionOptions.swift`; `Database.swift` (`DatabaseOptions.execution`);
`Statement.swift` (`setExecutionOptions`, `effectiveExecution`, plan cache `planningTag`).
**Evaluator:** `Eval.swift` (treeWalk + `applyAffinities` + raw `compareUTF8`/`NoCase`) · `CompiledEval.swift`
· (future) `SQL/VDBE/`. Seam: `Accumulator` thunks in `SelectExecutor.run`.
**Join:** `Executor.swift` `runInnerHashJoin`(:914)/`forEachFilteredRow`(:694)/`descend`(:738)/
`fastExistence`(:817) · `Planner.planJoin`(:128) (+ future `BoundJoin.driver`, `Plan.swift:87`) ·
`MergeJoin.swift` (todo).
**Insert:** `Relation/DML.swift` `insertCore`(:336)/`insertBatch` · `AppendCursor.swift` (todo) ·
`BTree.swift` `put`/`insertSeparator` · `TxnContext.swift` (scratch buffers, warm cache).
**God-files:** `SQL/Executor.swift`(1569), `SQL/Parser.swift`(1148), `SQL/Plan.swift`(975),
`SQL/Writer.swift`(686), `Relation/Relation.swift`(634), `Relation/DML.swift`(601).
**Reuse:** `GroupKey` (`Grouping.swift`), `Integrity.deepCheck` (`Integrity.swift`), `SimulatedDisk`
(`Tests/ADSQLTestSupport`), `TreeHandle.count` (`MetaPage.swift`), `KeyCodec.decode`,
`RowSlot.withTextBytes`/`loadMaterialized`, `RecordCodec.withText/withBlob`, `LatencyHistogram`/`formatRate`.
**Differential/property suites:** `SQLStrategyMatrixTests`, `SQLHashJoinTests`, `SQLJoinExistenceTests`,
`SQLSearchTopNTests`, `SQLDistinctIndexTests`, `RelationCodecTests`, `SQLEvalTests`, `FTSParityTests`,
`FTSWANDTests`, `CommitRecoveryTests`.

---

## 12. Out of scope here (separately tracked)

- **M7 DSL & metaprogramming** (RFC 0008 Act II, P0–P2; result-builder DSL + scoped `swift-syntax` macro
  plugin) — gated on M5/F5, not part of this health+perf program.
- **RFC 0005 Apple-native adoption** — `os.Logger`/`OSSignposter` (the perf-observability substrate),
  `import System` (fd/errno), Accelerate/SIMD + Compression (benchmark-gated), the swift-atomics-vs-
  `ADCAtomics` re-decision (decide on dependency-hygiene grounds; capability is not the blocker). May be
  adopted opportunistically inside RFC 0009 Phase 1 if it pays for itself; otherwise deferred.
- **M6 hardening + importer** — expanded fuzz/crash-injection, a SQLite-file importer; the FTS
  format-version bump + crash-injection feed it.

---

## Appendix A — Commit map

| Commit | Contents |
|---|---|
| `8ddcc9a` | owner's evaluator-strategy work + C3 (`loadBE64`) + SQL perf mechanisms (§4.5) |
| `6ccde9a` | R1/R2 read-path integrity guards + tests |
| `18e5cb7` | R3 thread-safe errno formatting |
| `509fa33` | S3 JSON parser unit tests |
| `7847e7c`, `991020c` | owner robustness/consistency |
| `86d9bde` | CI runs soak-tagged tests |
| `1c3bccf` | reports' baseline (FTS F6 postings memtable, F6f) |
| `f827ba7` | FTS F6g — frame-of-reference bit-packed postings codec |
| `5bcdcc6` | docs: F6g + the query-bottleneck finding |
| `40a85df` | FTS F6i — query-scoped score-all scorer |
| `5075a14` | FTS F6j — incremental WAND payload scan (O(block²)→O(block)) |
| `f0e0e5b` | FTS F6k — zero-copy sum-only docLength (**ADSQL beats FTS5 on ranked**) |
| `e2522d3` | FTS F6l — MATCH prefix-union merge + zero-copy key read *(peer, concurrent)* |
| `ad09d31` | FTS F6m — reuse single-term WAND field-TF buffer — widen ranked lead *(peer, concurrent)* |
| `e63b7a4` | **this review (0003) + RFC 0009** — Deliverable 0 of the health+perf program |
| `2d5f347` | FTS F6n — persistent stats cursor (`seekForward`) for docLength *(peer, concurrent)* — current HEAD |

## Appendix B — Source reports (archived verbatim)

- `docs/reviews/archive/2026-06-14-health-check-remaining-work.md`
- `docs/reviews/archive/2026-06-14-perf-maturity-status.md`

These are byte-for-byte; this review (0003) is the reconciled-to-HEAD synthesis and the RFC 0009 program is
the operational schedule. When the two disagree, **0003 + 0009 win** (they are reconciled to HEAD); the
archive preserves original phrasing and any detail not lifted verbatim above.

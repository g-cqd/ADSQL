# ADSQL

A from-scratch, **pure-Swift, SQLite-compatible embedded database** for Apple platforms.
Copy-on-write B+tree over `mmap`, single-writer / wait-free-reader MVCC, crash-safe by
construction. Swift 6.3 tools, module-wide `.strictMemorySafety()` (SE-0458) + experimental Lifetimes,
macOS 15 floor (device platforms at 26), **arm64 + x86_64** (16 KiB logical pages). One runtime
dependency: **ADJSONCore** — ADJSON's Foundation-free, swift-syntax-free JSON core, backing the SQL
JSON functions (`json_extract`, the `->`/`->>` path operators, json builders).

> **This file is the single source of truth** — architecture, current status, the vs-SQLite
> scorecard, and the prioritized backlog. It consolidates what were nine RFCs + three design
> reviews (now folded in here; the originals remain in git history). Code comments that cite
> `RFC 000x` / `Review 000x` / `F6x` refer to that history — they are kept as provenance.

**Modules:** `ADSQLKernel` (engine) · `ADSQL` (public façade, `@_exported`) · `ADSQLTool` (CLI) ·
`ADSQLBench` (benchmarks vs system SQLite + FTS5) · `ADSQLTestSupport` (reference model store,
seeded op generator, simulated disk for crash injection). Tests in `ADSQLKernelTests`.

---

## 1. Architecture & design

### Storage engine
- **COW B+tree over `mmap`** — 16 KiB pages, **XXH64** per-page checksums, overflow-page chains for
  large values, a page allocator + free-list that reclaims pages once no reader can still see them.
- Committed pages are **immutable**; a write transaction copies-on-write the pages it touches.

### Durability & concurrency
- **Single-writer / wait-free-reader MVCC.** Readers run lock-free against an immutable committed
  snapshot; one writer at a time mutates via a dedicated writer thread. A cross-process reader table +
  writer lock coordinate multiple processes.
- **Group commit** batches concurrent write requests; per-request undo lets one request roll back
  without aborting the batch.
- **Crash-safe by construction** — recovery is simply *picking the newest checksum-valid meta page*
  (meta ping-pong + one barrier). No WAL replay.
- **Durability profiles:** `.barrier` (`F_BARRIERFSYNC`, default), `.full` (`F_FULLFSYNC`), `.none`
  (bench). O(1) atomic snapshots via APFS `clonefile(2)`.

### SQL engine
- Pipeline: **lexer → parser → binder → heuristic planner → row-at-a-time executor → writer.**
- Surface: single-table & joined `SELECT` (INNER/LEFT), `WHERE` / projection / `ORDER BY` / `LIMIT` /
  `OFFSET` / `DISTINCT`, `GROUP BY` + `COUNT`/`SUM` + `HAVING`, `UNION`/`UNION ALL`,
  `INSERT`/`UPDATE`/`DELETE` + `RETURNING`, full DDL, `PRAGMA` compatibility, `BETWEEN`,
  `INSERT … SELECT`, `ON CONFLICT DO UPDATE` (upsert), correlated scalar subqueries,
  `db.transaction { }`, `CREATE TRIGGER`. Column refs are bound to `(table, column)` slots at bind
  time (no per-row string resolution). Differential-tested against system SQLite (CSQLite).
- The bound AST (`SQLExpr` / `SQLSelect` / `SQLStatementAST`) is public — the seam a future query DSL
  lowers into via `prepare(ast:)`.

### Execution-strategy framework
- `ExecutionOptions` selects, per database or per statement, an **evaluator** (`treeWalk` /
  `compiledClosures` / `vdbe`), a **join** strategy (`nestedLoop` / `hash` / `merge` / `auto`), and an
  **insert** path (`standard` / `hoisted` / `appendCursor`). **Defaults: `join=.auto`,
  `evaluator=.compiledClosures`, `insert=.standard`.**
- **Strategy-beside discipline:** a new strategy lands *beside* the reference path and only becomes a
  default once it wins on all **seven criteria** — accuracy, performance, concurrency, parallelism,
  reliability, consistency, integrity. Equivalence is locked by `SQLStrategyMatrixTests` (every
  strategy ≡ reference ≡ SQLite) and measured by `ADSQLBench`'s `StrategyBench` matrix. Nothing is
  retired while the program runs; a superseded path stays selectable one release.

### FTS5
- `CREATE VIRTUAL TABLE … USING fts5`, the `MATCH` operator, `bm25()` / **bm25f** per-column weights.
- Tokenizers: `unicode61`, `porter`, `trigram`. Postings codec uses frame-of-reference bit-packing,
  one block per key (O(n) incremental build). Ranked top-k uses **block-max WAND**. A transaction-
  scoped postings memtable coalesces a transaction's documents before flush.

### Safety model
- **Module-wide strict memory safety** (SE-0458): ~620 unsafe constructs each explicitly `unsafe` or
  encapsulated by a `@safe` type, so any *new* unsafe use is compiler-flagged.
- `~Escapable` / `~Copyable` + `RawSpan` lifetime dependencies bind page views to their snapshot
  (`Cursor`, `ReadTxn`/`WriteTxn`, `RowView`, `ValueRef`) — they cannot outlive it.
- **Typed throws** (`throws(DBError)`) below the façade; `Synchronization` `Mutex`/`Atomic` for
  in-process state; thread-safe libc (`strerror_r`).

### Public API & code structure
- Public surface (post-encapsulation): `Database`, `ReadTxn`/`WriteTxn`, `Statement`, `SQLParameters`,
  `SQLRow`/`Row`/`SQLColumnHeader`/`RunResult`, `Value`/`ColumnType`/`Collation`, `DBError`, the
  `Definitions` (table/column/index), `DatabaseOptions`/`ExecutionOptions`/`DurabilityProfile`,
  `IntegrityReport` + `verifyIntegrity`. The **entire storage engine is `package`** (B-tree, pager,
  cursors, codecs, catalog, txn context) — invisible to external consumers, reachable in-package.
- No `ADSQLKernel` source file exceeds ~600 lines (the executor/parser/binder/storage layers are split
  into concern-scoped files).

---

## 2. Status

| Milestone | Status | Scope |
|---|---|---|
| **M0–M2 — Storage kernel** | ✅ done | COW B+tree over mmap; MVCC; free-list; commit protocol + crash-injection recovery; cross-process readers + writer lock; group commit. |
| **M3 — Relational layer** | ✅ done | Strict typed `Value`/columns; order-preserving `KeyCodec`; `RecordCodec`; catalog + transactional DDL; DML with conflict policies + secondary-index maintenance; FK `ON DELETE CASCADE/RESTRICT`; deep integrity (index ⇄ row bijection). |
| **M4 / M4.5 — SQL front end** | ✅ done | The full SQL pipeline + completeness (PRAGMA, BETWEEN, INSERT…SELECT, upsert, correlated scalar subqueries, transactions). Differential-tested vs CSQLite. |
| **M4.6–M4.8 — Scan/query perf** | ✅ done | Zero-copy row decode, bounded top-N, residual-conjunct elimination, ordered rowid fetch, lazy `RowView` scans, `DISTINCT` O(n²)→O(n), index-nested-loop join, slot-bound columns. Strict memory safety enabled module-wide. |
| **M5 — FTS + bm25/bm25f** | ✅ mostly done | FTS5 virtual tables, `MATCH`, `bm25`/`bm25f`, unicode61/porter/trigram, block-max WAND, trigger sync. **ADSQL beats SQLite FTS5 on ranked top-k.** Small F6 tail remains (see backlog B). |
| **Health + perf program (R1–R7)** | ✅ done | General 2-table merge join + `.auto` cost model (**JOIN now ~2.1× faster than SQLite**); hoisted insert + a `sample`-profiled, evidence-based closure of the INSERT gap as inherent; compiled-evaluator default flip; god-file splits (no file > ~600 lines); `public`→`package` storage encapsulation (external surface −35%); seven-criteria `StrategyBench`; FTS bench breadth. |
| **M6 — Hardening** | ⏳ future | Expanded fuzz / crash-injection; ops polish. *(The SQLite-file importer moved up — it is now **F1 of M8**.)* |
| **M7 — Query DSL & metaprogramming** | ⏳ deferred below M8 | Type-safe, injection-safe query DSL + a scoped `swift-syntax` macro tier. |
| **M8 — apple-docs read-engine swap** | ⏳ **active — top priority** | Become the engine *inside* apple-docs' `libAppleDocsCore` (Bun + `bun:ffi`, frozen `ad_storage_*` C ABI), replacing dlopen'd libsqlite3 — `/search` ceilings at ~32 req/s on memory-bandwidth contention. **Adoption gate (apple-docs RFC 0001):** ✅ F1 importer · ✅ F2 FTS byte-parity · ✅ main-query surface parity (`AppleDocsMainQueryTests`) · ✅ **F0 Linux x64/arm64** (builds + full `swift test` suite green on x64+arm64) · **INT** — ✅ Swift side (`ADSQLSearch.searchPagesFramed`, §2.5 byte-parity-proven); remaining is the cross-repo `@_cdecl` shim + `Storage` wiring in apple-docs. **Then read-path perf:** ✅ F6 denorm → ✅ **F4 covering** → ✅ **F5 streaming** (`Statement.forEach`, bounded-memory row-at-a-time, SQLite's `step` model) → P1/P2 boundary collapse (A1–A7). See **[RFC 0010](docs/rfcs/0010-apple-docs-integration.md)**. |

### Scorecard vs system SQLite (apple-docs shapes, M-series, 200k rows / 2k FTS docs)

| Path | Standing | Notes |
|---|---|---|
| cold open → first get | **~5–13× faster** ✅ | newest-meta recovery, no WAL |
| point / rowid get (p50) | **~3–4× faster** ✅ | |
| full scan throughput | **≈ parity** ✅ | ~4.3 GB/s |
| 16 concurrent readers under write churn | **~2–3× faster, ½ tail** ✅ | wait-free MVCC |
| `SELECT DISTINCT` (dup-heavy) | **~2× faster** ✅ | O(n) GroupKey + slot binding |
| `sql search` (filter + ORDER BY/LIMIT) | **≈ parity** ✅ | zero-copy top-N + compiled eval |
| **JOIN** (indexed equi-join) | **~2.1× faster** ✅ | merge fast path via `.auto` default |
| **FTS ranked top-k** | **~2.3× faster** ✅ | block-max WAND + zero-copy docLength |
| **INSERT** (batch, 3-index) | **~0.8×** ⚠️ | residual is the inherent Swift-vs-C per-op tax over a shared B+tree algorithm (profiled); safe relational waste already cleared |
| **FTS MATCH** (membership) | **~3.3× slower** ⚠️ | rides the general per-row path |
| **FTS index build** | **~7× slower** ⚠️ | constant factor vs FTS5 segments |
| **FTS delete / churn** | **~390× slower** ⚠️ | re-encodes postings per doc → O(corpus); the standout gap |
| **apple-docs `/search`** (real 4 GB, 8-way) | **~2.2× faster** ✅ (F6 + invariant-fold) | DEFINITIVE test: ADSQL(F6-denorm) **wins at production concurrency — 223 vs 101 req/s** at 8-way (ADSQL scales **6.3×**; SQLite ceilings **1.4×**, peak 131@4 then regresses — the §1 signature, confirmed); crosses between 4–8 threads, gap widens with cores. Invariant-subexpr folding cut single-thread 29→24.5 ms (~3× slower than SQLite, down from ~6×). The wait-free-MVCC thesis: wins *throughput*. Denorm-equivalence + import byte-parity-verified at 358k docs |

> **apple-docs read path (M8) — measured, not assumed:** the `ADSQLBench search` scenario shows the
> as-built composed `/search` query is **~26× slower than SQLite** (the `ORDER BY tier, rank` shape
> defeats block-max WAND — see the row above). The **target** — served **index-only off a covering FTS
> index** under wait-free MVCC (working set = covering postings, not the 4 GB base table) — is the M8
> **P0b** program: ✅ F6 denorm (→ rank-only, no JOIN), A5 pushed filters, ✅ F4 covering, A2–A4 streaming.
> The FTS *delete/churn* + *index-build* gaps are **off** the read path (the importer builds the FTS
> once; `/search` never writes) — but the **import** cost is now concrete (~6k docs/s, so the 353k-doc
> corpus is a multi-minute one-time build). See RFC 0010.

---

## 3. Future work (prioritized backlog)

> **Driving program — apple-docs read-engine integration (M8, [RFC 0010](docs/rfcs/0010-apple-docs-integration.md)).**
> The end goal is concrete: ADSQL becomes the engine *inside* apple-docs' `libAppleDocsCore` (Bun +
> `bun:ffi`, frozen `ad_storage_*` ABI), replacing libsqlite3. The backlog is **sequenced by M8's
> two-stage critical path** — first the **adoption gate** (✅ **F1** importer · ✅ **F2** FTS byte-parity ·
> ✅ main-query surface parity · ✅ **F0 Linux x64/arm64** (builds + suite green) · **INT** the ABI
> swap), then **read-path perf** to beat SQLite (**F6** denorm → **F4** covering → **F5** streaming, then
> P1/P2 boundary-collapse **A1–A7**: compiled FTS-search primitive, caller row encoder, one-call
> `searchFramed(into:)`, mmap→out single-copy, pushed filters, snapshot/plan cache). Items below carry
> their **F#/A#** where they feed M8; **VDBE** and **M7 (Query DSL)** are deferred below it.

### A. Performance levers (open)
- **VDBE register machine** — a flat opcode loop over a `[Value]` register file (the deep evaluator
  lever). Deferred on evidence that read paths are **access-path-bound** (the compiled closures are
  already ≈ tree-walk on realistic queries); revisit only if an eval-heavy workload justifies it.
  Multi-week — **deferred below M8** (the apple-docs read path is access-path-bound, not eval-bound).
- **`ANALYZE` + statistics + real cost model** — replace the heuristic access-path/join scoring with
  per-index selectivity so the planner picks scan-vs-seek and the right join strategy on cost.
- **Covering / `INCLUDE`-index serving** **(M8 F4 · ✅ done)** — answers queries straight off the index
  cursor with no base-table descent. The binder proves "required cols (bound projection ∪ residual WHERE
  ∪ HAVING ∪ ORDER BY ∪ GROUP BY ∪ probe values) ⊆ {rowid-alias} ∪ {INCLUDE}" (single-table, non-aggregated,
  no correlated refs), stamps the `.index` plan `covering`, and the executor serves rows via
  `RowCursor(coveringIncludes:)` with no descent. The served set is **stricter than `key ∪ includes`** —
  a non-rowid KEY column is not in the entry value, so it forces a descent (correctness over optimization).
  Pinned by `SQLCoveringIndexTests` (positive / negative / reversed-INCLUDE-order / direct binder-decision)
  vs the no-index scan oracle **and** SQLite. *Follow-on:* equality-probed key-column values are statically
  known (= the probe constant) and could be served without descent — a future widening, not yet done.
- **Ordered/batched rowid sweep + `madvise` prefetch** (bitmap-heap-scan style); **per-page zone maps
  (min/max)** to skip leaf pages on filtered scans; **batch-at-a-time filter evaluation**;
  **correlated-subquery decorrelation / index-probe.**
- **Zero-copy reads on UPDATE/DELETE/`materializeRow`**; drop the residual write-path `Array(s.utf8)`
  copies (trivial).
- **FTS:** the **delete/churn re-index path** (the ~390× gap — re-encodes postings per doc);
  **raw-segment postings** for build throughput (architectural); MATCH membership rides the general
  row path.
- **Deferred (documented, unscheduled):** spillable external merge-sort (removes the top-N cliff and
  unblocks sort-merge join); morsel-parallel scans (natural under multi-reader MVCC); COW write-path
  page-copy tuning.

### B. FTS completion (M5 tail)
- **M8 F2 — FTS byte-parity gate:** the engine is parity-*capable* (bit-identical bm25f, deterministic
  `WANDTopK` tie-break), but the **proof against the apple-docs corpus is pending** — extend
  `FTSParityTests` to run the query corpus through both engines and diff ranked order (RFC 0010).
- Finish the prefix-union / zero-copy key-read path; `snippet()` / `highlight()` SQL functions (**not
  yet supported**); remaining bench shapes (contentless `documents_body_fts`, prefix/`columnsize=0`
  `sf_symbols_fts`); a concurrent-FTS-reader bench arm.

### C. Hardening + importer
- The **SQLite-file importer** (loose→strict coercion + manifest-driven FTS5 reconstruction + build-time
  denormalization) is **M8 F1 + F6 — the swap gate** (RFC 0010), no longer a generic M6 item.
- Remaining M6: expanded fuzz / crash-injection coverage; operational polish.

### D. M7 — Query DSL & metaprogramming (deferred below M8; gated on the AST seam, which is ready)
- **P0 (dependency-free core):** a result-builder query/DDL DSL + operator-overload expression DSL that
  lowers to the public AST via `prepare(ast:)` (injection-safe, non-`Equatable` expression wrapper).
- **P1 (macro tier):** an isolated `ADSQLMacros` `swift-syntax` plugin (kernel + façade stay zero-dep)
  providing `#SQL`, `@Table`, and `@dynamicMemberLookup` on eager `SQLRow`/`Row`.
- **P2 (internal codegen):** `@FixedLayout` (Meta / PageHeader), an `SQLExpr.mapChildren` walk
  refactor, `callAsFunction` on a typed `Query<Output>`.

### E. Deferred SQL features (parsed-and-rejected today; the compatibility registry)
- **Subqueries:** `EXISTS`, FROM-clause subqueries, `IN (SELECT …)` (beyond the `json_each` shape),
  compound scalar subqueries.
- **Aggregates:** `AVG`, `MIN`, `MAX`, `TOTAL`, `GROUP_CONCAT`, `COUNT(DISTINCT …)`.
- **Query:** CTEs (`WITH`), window functions, `EXCEPT` / `INTERSECT`,
  `NATURAL`/`RIGHT`/`FULL`/`CROSS`/comma joins, `JOIN … USING`, `SELECT` without `FROM`.
- **Operators:** `GLOB`, `REGEXP`, `LIKE … ESCAPE`, `IS` beyond `IS [NOT] NULL`.
- **DDL/DML:** `ALTER TABLE`, `CREATE VIEW`, partial indexes, `DESC` index columns, `WITHOUT ROWID`,
  `PRIMARY KEY DESC`, `ON DELETE` actions beyond `CASCADE`/`RESTRICT`, `DEFAULT` exprs beyond
  `datetime('now')`, `ON CONFLICT … DO UPDATE … WHERE`.

### F. Swift-API adoptions (benchmark-gated where noted)
- **swift-collections:** `Deque` (writer queue), `OrderedDictionary` (statement cache + GROUP BY),
  `Heap` (bounded top-N), `BitSet` (rowid dedup), `OrderedSet` (DISTINCT).
- **Memory-safe primitives:** `RawSpan`/`MutableSpan` in the codecs + page writers, `InlineArray` for
  fixed-width scratch, `UTF8Span` allocation-free compare, `@inlinable` decode primitives, SIMD byte
  scanning.
- **Instrumentation/system:** `OSSignposter` + `os.Logger`; `import System` for fd/errno; Accelerate /
  vDSP + the Compression framework (both gated on `ADSQLBench`).
- **Audits:** explicit atomic memory orderings; complete typed-throws adoption; `Sendable`.

### Explicitly declined (recorded so they aren't re-litigated)
`EXPLAIN`, `VACUUM`; `vm_copy` COW (full memcpy is faster); Point-Free packages
(structured-queries / sqlite-data / parsing); novel custom operator symbols (named methods instead);
`@dynamicCallable` (stringly-typed); property-wrapper schema markers (peer macros instead);
Codable-style codec macros (the byte format is deliberately hand-tuned); a `DBError.description`
macro; strong-ID typedefs `PageNumber`/`Generation` (page arithmetic is pervasive `UInt64`, so
wrappers add `.rawValue` noise without catching bugs at that layer).

---

## 4. Engineering disciplines

- **Standing gate (every change):** `swift build` clean (0 warnings, 0 strict-MS over-marks) ·
  `swift test` green · `swift test --sanitize=thread` on changed read/write/scan paths (the full-suite
  TSan exceeds the tool budget → the concurrency-relevant subset is run) · crash-injection on write
  paths · `ADSQLBench` perf-neutral-or-better · **one concern per commit.**
- **Evidence-driven:** every performance claim sits behind an `ADSQLBench` number; diagnoses come from
  a profile, not a guess.
- **Strategy-beside + selection/retirement:** alternative execution strategies are added beside the
  reference path and graduate to a default only on a **seven-criteria** win, validated by the
  differential matrix + `Integrity.deepCheck`; the superseded path stays selectable one release.

## Develop

```sh
swift build
swift test
swift test --sanitize=thread          # concurrency lane (run a relevant subset)
swift run -c release ADSQLBench        # vs system SQLite (+ FTS5)
```

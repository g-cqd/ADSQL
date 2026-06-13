# Review 0002 — Performance & Architecture

Status: review, 2026-06 (post-M4.7). Scope: a thorough pass over performance,
architecture, and algorithmic complexity across the storage engine, query executor,
codecs, and concurrency — grounded in the state-of-the-art literature and in how the
leading SQL/embedded engines (SQLite, DuckDB, LMDB, PostgreSQL) solve exactly what ADSQL
struggles with. The actionable, phased program derived from this review lives in
**RFC 0004**; this document is the evidence and the reasoning.

Method: two structured passes over the storage and query layers, every finding verified
first-hand against the code (`file:line`), plus two cited research syntheses. Framing is
**measurement-first** — the lesson of RFC 0002, where the obvious hypothesis (per-row
record copy) moved the benchmark by ~0.1 ms and the real wins were algorithmic. Each
finding is tagged with complexity and a severity; each recommendation with ROI/effort/risk.

## Verdict

The core architecture — **mmap + copy-on-write B+tree + single-writer / wait-free-reader
MVCC + no WAL + lazy per-column decode** — is sound and well-matched to ADSQL's embedded,
read-mostly, SQLite-compatible niche. It is the near-exact architecture of **LMDB**, which
is the strongest validation in the literature (Chu, SDC15). ADSQL already *leads* SQLite on
the read-mostly paths (cold open 5×, point get 3.6×, 16-reader throughput 2.3×). Do not
rewrite the engine.

The performance deficits are localized and, with one exception, **algorithmic, not
architectural** — they are recoverable without abandoning the design:

| Gap | Now | SQLite | Δ | Verified root cause |
|---|---|---|---|---|
| (a) `sql search` (filter + ORDER BY/LIMIT) | ~5.0 ms | 1.76 ms | **0.35×** | per-row index→table descent + `cellOffsets` work |
| (b) relational index scan | ~2.2 M/s | ~3.1 M/s | **0.69×** | per-row index→rowid→table descent (constant factor) |
| (c) batch insert (SQL / 3-index) | 143 k/s | 224 k/s | **0.64×** | B+tree COW write path (full root→leaf copy + write) |
| joins / correlated subqueries | — | — | — | inner relation full-scanned per outer row even when an index exists → O(M·N) |

Gap (c) is the one *architectural* tradeoff (COW shadow-paging buys crash-safety and
wait-free reads at the cost of write amplification — LMDB makes the same trade); the rest
are addressable algorithmically. The single highest-leverage correctness-of-complexity bug
is that **joins never use an index** (§Query F2).

## Findings

Severity: **S1** = wrong asymptotic complexity / scales badly; **S2** = real constant-factor
cost on a hot path; **S3** = minor / latent.

### Storage engine

| # | Finding | Site | Complexity | Sev |
|---|---|---|---|---|
| ST1 | COW shadow-paging copies the **entire root→leaf path per write** (`PageBuf(copying:)`, ~5×16 KiB); splits cascade up the spine | `TxnContext.shadow:101-119`, `BTree.swift` | O(depth) page copies/write, O(depth²) on cascading split | S2 (inherent COW trade) |
| ST2 | **No leaf sibling-links**: a scan crossing a leaf boundary pops the branch stack and re-descends the sibling subtree | `Cursor.stepLeaf:188-206` (comment: "COW trees have no sibling links") | O(depth) per leaf *boundary*; amortized over ~100s of rows/leaf ⇒ ≈O(N) small constant | S2 |
| ST3 | Group-commit **double-clones** a page touched by >1 request in a batch | `TxnContext.shadow:103-108` | extra 16 KiB copy per shared page per request | S3 (justified: per-request rollback isolation) |
| ST4 | Free-list harvest **re-seeks from the root on every entry delete** | `FreeList.harvest` | O(E·log²F) instead of O(E·logF) | S3 |
| ST5 | In-node search is binary but does a **full memcmp per compare; no prefix compression** | `NodeBuilder.search` | O(logK) compares × full key length | S3 |
| ST6 | Read path is genuinely zero-copy (mmap), `MADV_RANDOM`, 0 syscalls/read | `MMap.pageBytes:35`, `Pager` | O(depth) page faults worst case | — (good) |

Note on ST1: this is the LMDB bargain (Chu) — reads are near-hardware-limited because
writes pay COW amplification. It is a *deliberate* trade, not a bug; the lever is reducing
per-write copies (ST3, larger group-commit batches), not abandoning COW.

### Query execution

| # | Finding | Site | Complexity | Sev |
|---|---|---|---|---|
| Q1 | Volcano executor, but **fully materializes** `rows` + `sortKeys` as `[[Value]]` before sorting | `Executor.swift:6, 215` | O(N) memory even for `LIMIT k` once N>4096 | S2 |
| **Q2** | **Joins always full-scan the inner table even when an index exists on the join column** — the descend driver hardcodes `.table` | `Executor.forEachFilteredRow:391` | k-way join **O(n₁·n₂·…·nₖ)** | **S1** |
| **Q3** | **`SELECT DISTINCT` is O(n²·m)** — linear scan of kept rows per row — while UNION/GROUP BY already hash via `GroupKey` | `Executor.deduplicate:799-820` (its own comment: "Quadratic… PR5 replaces this with canonical-key hashing") | O(n²·m) vs available O(n) | **S1** |
| Q4 | Correlated scalar subquery **re-executes the inner query per outer row**; no decorrelation/caching, and the inner side is itself nested-loop | `Statement.runScalarSubquery`, `Executor` outer-env | O(N·f(M)) | S1 (bounded by usage) |
| Q5 | Planner is a **pure heuristic with no statistics**: `score = prefixLen*4 + (hasTrailing?2:0) + (unique?1:0)` | `Planner.swift:172` | can pick a poor index; can't choose scan-vs-seek or join order on cardinality | S2 |
| Q6 | Bounded top-N is correct but **capped at a hardcoded 4096**; above it, full materialize + `indices.sorted` (in-memory only, no spill) | `Executor.swift:148`, `sortedOrder:826` | O(N·logN·m); O(N) memory; OOM risk on huge sorts | S2 |

### Codecs / allocation

| # | Finding | Site | Sev |
|---|---|---|---|
| C1 | `Array(s.utf8)` allocated per text cell on the **write/index path** (could append `s.utf8` directly) | `RecordCodec.encode:37`, `KeyCodec.append:52,55` | S3 |
| C2 | Hot-path *comparison* is already allocation-free (`SQLCompare` iterates `.utf8`); incremental single-column decode already landed (M4.7/B1) — residual `cellOffsets` work remains | `Eval.swift:74`, `RecordCodec.cellOffsets` | — (largely good) |

### Concurrency / durability

Single-writer + group commit (one `F_BARRIERFSYNC`/batch for `.barrier`, two
`F_FULLFSYNC` for `.full`) is sound and is a genuine strength (it beats SQLite WAL on
no-sync and bulk paths). The cross-process reader table + COW reclamation horizon are
correct. The `@safe`/Span memory-safety posture is audited separately in **Review 0001**
and not repeated here. One forward note: a single long-lived reader pins the COW
reclamation horizon and can grow the file (version bloat) — the in-memory-MVCC analog is a
known concern (Böttcher et al., VLDB 2019); worth an explicit oldest-reader metric.

## State of the art (cited) — with fit/no-fit for an OLTP mmap row store

> Per the review's scope: the full landscape is covered, each labeled for fit. ADSQL is
> OLTP/read-mostly; OLAP techniques are included for completeness and marked accordingly.

| Technique | Source | Fit |
|---|---|---|
| Volcano / iterator (pull) | Graefe, TKDE 1994 [1] | **Is** the model. Right for point/short-range OLTP. |
| Vectorized execution (batches) | MonetDB/X100, Boncz et al., CIDR 2005 [2] | **Partial.** Batch-at-a-time *filter* eval fits a row store; a full columnar engine does not. |
| Compiled / JIT plans (push) | HyPer, Neumann, VLDB 2011 [3] | **No** for OLTP (compile latency > savings). Borrow only the "flat monomorphic scan loop" idea (cf. SQLite VDBE). |
| In-memory hash join | Blanas et al., SIGMOD 2011 [4] | **Yes** — the highest-value join addition for unindexed equi-joins. |
| Radix / partitioned hash join | Balkesen et al., ICDE 2013 [5] | **Later** — premature; plain hash join captures most of the win. |
| Sort-merge join | Kim et al., VLDB 2009 [6]; Balkesen, VLDB 2013 [7] | **Later** — exploit *existing index order*, don't build a SIMD sorter. |
| LSM-tree | O'Neil et al., 1996 [8] | **No** — B+tree is right for read-mostly; LSM only if write-saturated. |
| Cache-conscious B+tree (CSB+) | Rao & Ross, SIGMOD 2000 [9] | **Partial** — node sizing + prefix compression help; pointer-elision fights mmap/COW page stability. |
| Bw-tree (latch-free) | Levandoski et al., ICDE 2013 [10] | **No** — single writer makes latch-freedom unnecessary. |
| mmap COW B+tree | LMDB, Chu, SDC15 [11] | **Architectural twin** — validates the design; mirror its free-list + dual-meta commit. |
| Optimistic / in-place MVCC | Hekaton, SIGMOD 2013 [12]; HyPer MVCC, SIGMOD 2015 [13] | **No** (multi-writer / in-place+undo). COW out-of-place is the better mmap fit; borrow precision-locking only if serializability is wanted. |
| MVCC GC / reclamation horizon | Böttcher et al., VLDB 2019 [14] | **Yes** — track an explicit oldest-reader horizon to bound COW file growth. |
| Late materialization | Abadi et al., ICDE 2007 [15] | **Yes** — ADSQL's lazy decode is the row-store analog; evaluate predicates before materializing. |
| SIMD predicate eval / branch reduction | Zhou & Ross, SIGMOD 2002 [16] | **Partial** — branch-free comparators on hot scans; full SIMD wants columns. |
| B+tree prefetching (pB+-trees) | Chen, Gibbons, Mowry, SIGMOD 2001 [17] | **Yes** — `madvise(WILLNEED)` / touch the next leaf to hide page-fault latency. |
| Zone maps / min-max skipping | Ziauddin et al., VLDB 2017 [18]; DuckDB [19] | **Yes** — per-page min/max skips leaf pages, avoiding the dominant mmap page-fault cost. |
| Morsel-driven parallelism | Leis et al., SIGMOD 2014 [20] | **Yes (later)** — multi-reader MVCC makes parallel scans natural. |
| "mmap is bad for a DBMS" | Crotty, Leis, Pavlo, CIDR 2022 [21] | ADSQL **already neutralizes** the transactional-safety argument (COW + single writer = the out-of-place discipline the paper says you're forced into). Residual risks: synchronous page-fault stalls and `SIGBUS` error handling for larger-than-RAM DBs. |

## How the leaders solve ADSQL's gaps (cited)

**Gap (b) — the index→rowid→table descent.** SQLite states the cost outright: an indexed
lookup is "**two binary searches**" (index, then table by rowid) and is mitigated not by
making the second seek faster but by *avoiding* it — **covering indexes** ("never look up
the original table row… can make many queries run twice as fast") and **WITHOUT ROWID**
(index-organized tables) [22][23]. PostgreSQL does the same with **index-only scans** gated
on a visibility map [24], and converts random rowid lookups into a sorted sweep with
**bitmap heap scans** ("do the heap accesses in sorted order") [25]. LMDB shows a pure
descent should be near hardware-limited [11] — so ADSQL's 0.69× is almost certainly
**constant-factor** (ARC/retain traffic, interior-node re-decode, re-walking from the root
per seek), which means *profile first*.

**Gap (a) — filtered scans.** SQLite's VDBE is a flat, register-based bytecode loop — a
`switch` over ~190 opcodes with compile-time register allocation and **no per-operator
virtual dispatch per row** [26], which is why an interpreted single-threaded engine still
scans fast. DuckDB adds **zone maps** (skip row groups whose min/max can't match) [19],
~2k-value **vectors**, and **morsel** parallelism [20] — the transferable pieces being zone
maps and batch-at-a-time filtering, not the columnar rewrite.

**Gap (c) — joins.** PostgreSQL's **hash join** builds a table on the smaller input and
probes with the larger (O(N·M) → ~O(N+M)), with hybrid batching when it spills and
load-factor accounting on *distinct* keys to avoid batch explosion [27]. The cheaper first
step ADSQL is missing entirely is **index-nested-loop**: when the inner join column has an
index, probe it instead of full-scanning (O(M·N) → O(M·log N)). Both need a real **cost
model** — SQLite's NGQP keeps the N best partial join orders and uses `ANALYZE`/`sqlite_stat`
selectivity [28][29].

## Prioritized recommendations (full detail + benchmarks in RFC 0004)

**P0 — measure, then cheap asymptotic wins**
- **Profile the rowid descent** against LMDB's "descent + pointer" ideal before optimizing it (IRON LAW + [11]); the 0.69× is likely ARC/retain + interior re-decode + root re-walk. *(ROI: high, effort: low, risk: none.)*
- **`SELECT DISTINCT` O(n²)→O(n)** by reusing the existing `GroupKey` hashing (`Executor.deduplicate:799`). *(ROI: high, effort: trivial, risk: low — code already exists.)*
- **Index-nested-loop join** — probe an index on the inner join column instead of `.table` (`Executor.forEachFilteredRow:391`); O(M·N)→O(M·logN). *(ROI: high, effort: med, risk: med — held by differential suite.)*

**P1 — scan / descent (gaps a, b)**
- **Covering / `INCLUDE` indexes**: serve a query whose columns are all in the index straight from the index cursor; skip the rowid descent [22][24]. *(ROI: high, effort: med.)*
- **Ordered/batched rowid lookup** (bitmap-heap-scan style [25]): buffer matching rowids → sort → sweep the table in rowid order; reuse the cursor page-stack across consecutive seeks (`seekForward` already exists, M4.7/B7); `madvise(WILLNEED)` the next leaf [17]. *(ROI: high, effort: med.)*
- **Per-page zone maps (min/max)** on key/filter columns to skip whole leaf pages on filtered scans [18][19] — avoids the dominant mmap page-fault cost. *(ROI: med-high, effort: med.)*

**P2 — joins, planner, scan loop (gaps a, c)**
- **In-memory hash join** (build smaller, probe larger), planner-gated by build-side estimate, falling back to nested-loop [27][4]. *(ROI: high for analytical joins, effort: med-high.)*
- **Lightweight `ANALYZE`/statistics** → a real cost model for access-path + join selection (replaces the `Planner.swift:172` heuristic) [28][29]. *(ROI: med, effort: med — enabler for the above.)*
- **Batch-at-a-time filter evaluation** — transpose a decoded batch into transient column vectors for the predicate; the row-store-fitting slice of vectorization [2]. *(ROI: med, effort: med, behind a benchmark.)*
- **Correlated subquery**: index-probe the correlation per outer row / decorrelate. *(ROI: med, effort: med.)*
- **Drop write-path `Array(s.utf8)` copies** (C1). *(ROI: low, effort: trivial.)*

**P3 — long-term / explicitly out of scope (with rationale)**
- Spillable external **merge sort** (unblocks large ORDER BY + a future sort-merge join) [6][7]; **morsel-parallel** scans [20]; reducing COW write-path page copies (gap c — inherent trade).
- **No-fit (documented why):** full vectorized/columnar engine, JIT-compiled plans, radix-partitioned joins, Bw-tree, in-place+undo MVCC, LSM.
- **mmap residual risks** [21]: handle `SIGBUS`, accept synchronous page-fault stalls for >RAM DBs; mitigate with `madvise`. Document as known limitations.
- **FTS5 (M5)** forward pointer: the inverted-index/`bm25` work is the next milestone; its algorithmic choices (postings layout, tokenizer cost, position lists) deserve their own design note — out of scope here.

## Measurement update (post-INLJ, M4.8) — gap (b) re-attributed

P0.2 (DISTINCT O(n)), P2.5 (write-path allocs), and P0.3 (index-nested-loop
join) shipped. Profiling the join probe (the IRON LAW gate on P0.1/P1.2) **moved
the diagnosis**: the index→rowid→table *descent is not the bottleneck*.

- `sql join` 100k self-join: **rowid** probe (single descent) p50 **101 ms** vs
  **secondary-index** probe (double descent + TEXT key) **223 ms**; SQLite
  in-loop **21.7 ms**. So the second descent costs ~120 ms — but even the
  *single*-descent rowid join is ~4.6× SQLite, and ADSQL's standalone rowid get
  *beats* SQLite (0.8 vs 2.2 µs). The fetch is competitive.
- The gap is the **per-row interpreter**, not the descent: `SQLEval` walks the
  expression tree per row, and the row env re-resolves every column access via
  `QueryBinding.resolve(qualifier,name)` — a `name.lowercased()` **string
  allocation + dict lookup on every access, every row** (`Plan.swift:65`;
  `.column`'s parsed `offset` is the source position, ignored by the evaluator,
  `Eval.swift:188`). SQLite's VDBE is a flat register loop with no per-row
  dispatch or name resolution. This refines this review's gap-(b) attribution
  ("ARC/retain, interior re-decode, root re-walk") — the dominant cost is column
  re-resolution + tree-walk dispatch.

**Revised lever (supersedes P1.2 cursor-reuse / zone maps for gap b):** bind
column references to precomputed `(table, column)` slots at bind time so the
evaluator skips per-row string resolution — a focused evaluator/AST change that
benefits the **filtered scan (gap a, the consumer's search path)**, index scans,
and joins alike. Cursor-reuse across probes was considered and rejected: probes
are unordered (warm `seekForward` won't hit), `RowCursor` is `~Copyable` (no
array of per-depth cursors), and the alloc is not the dominant cost. The
VDBE-style flat scan loop (review §SOTA [26]) is the same lever taken further.

## Risks & non-goals

- **Measurement-first**: every perf item ships behind an `ADSQLBench` number that moves; P0 profiling gates the P1 descent work. Do not repeat RFC 0002's "optimize the wrong thing".
- **No result changes**: the superset+residual contract (RFC 0001) + differential suites vs CSQLite are the correctness gate for every change.
- **Don't** prescribe OLAP rewrites for an OLTP engine, add dependencies (zero-dep stance), or undo the COW/mmap/single-writer design that LMDB validates and that wins ADSQL its read-path lead.

## References

[1] Graefe, "Volcano — An Extensible and Parallel Query Evaluation System," TKDE 1994. https://dl.acm.org/doi/10.1109/69.273032
[2] Boncz, Zukowski, Nes, "MonetDB/X100: Hyper-Pipelining Query Execution," CIDR 2005. https://www.cidrdb.org/cidr2005/papers/P19.pdf
[3] Neumann, "Efficiently Compiling Efficient Query Plans for Modern Hardware," PVLDB 2011. https://www.vldb.org/pvldb/vol4/p539-neumann.pdf
[4] Blanas, Li, Patel, "Design and Evaluation of Main Memory Hash Join Algorithms for Multi-core CPUs," SIGMOD 2011. https://dl.acm.org/doi/10.1145/1989323.1989328
[5] Balkesen, Teubner, Alonso, Özsu, "Main-Memory Hash Joins on Multi-Core CPUs," ICDE 2013. https://dblp.uni-trier.de/rec/conf/icde/BalkesenTAO13.html
[6] Kim et al., "Sort vs. Hash Revisited," PVLDB 2009. https://dl.acm.org/doi/10.14778/1687553.1687564
[7] Balkesen et al., "Multi-Core, Main-Memory Joins: Sort vs. Hash Revisited," PVLDB 2013. https://www.vldb.org/pvldb/vol7/p85-balkesen.pdf
[8] O'Neil, Cheng, Gawlick, O'Neil, "The Log-Structured Merge-Tree," Acta Informatica 1996. https://www.cs.umb.edu/~poneil/lsmtree.pdf
[9] Rao, Ross, "Making B+-Trees Cache Conscious in Main Memory," SIGMOD 2000. https://cadmo.ethz.ch/education/lectures/FS17/SDBS/RaoRoss-sigmod00.pdf
[10] Levandoski, Lomet, Sengupta, "The Bw-Tree: A B-tree for New Hardware Platforms," ICDE 2013. https://www.microsoft.com/en-us/research/publication/the-bw-tree-a-b-tree-for-new-hardware/
[11] Chu, "LMDB: Lightning Memory-Mapped Database," SNIA SDC15. https://www.snia.org/sites/default/files/SDC15_presentations/database/HowardChu_The_Lighting_Memory_Database.pdf
[12] Diaconu et al., "Hekaton: SQL Server's Memory-Optimized OLTP Engine," SIGMOD 2013. https://www.microsoft.com/en-us/research/wp-content/uploads/2013/06/Hekaton-Sigmod2013-final.pdf
[13] Neumann, Mühlbauer, Kemper, "Fast Serializable MVCC for Main-Memory Database Systems," SIGMOD 2015. https://dl.acm.org/doi/10.1145/2723372.2749436
[14] Böttcher, Leis, Neumann, Kemper, "Scalable Garbage Collection for In-Memory MVCC Systems," PVLDB 2019. https://db.in.tum.de/~boettcher/p128-boettcher.pdf
[15] Abadi, Myers, DeWitt, Madden, "Materialization Strategies in a Column-Oriented DBMS," ICDE 2007. http://www.cs.umd.edu/~abadi/papers/abadiicde2007.pdf
[16] Zhou, Ross, "Implementing Database Operations Using SIMD Instructions," SIGMOD 2002. https://dl.acm.org/doi/10.1145/564691.564709
[17] Chen, Gibbons, Mowry, "Improving Index Performance through Prefetching," SIGMOD 2001. https://www.pdl.cmu.edu/PDL-FTP/Database/pf_final.pdf
[18] Ziauddin et al., "Dimensions Based Data Clustering and Zone Maps," PVLDB 2017. https://vldb.org/pvldb/vol10/p1622-ziauddin.pdf
[19] DuckDB, "Indexing / zonemaps." https://duckdb.org/docs/current/guides/performance/indexing
[20] Leis, Boncz, Kemper, Neumann, "Morsel-Driven Parallelism," SIGMOD 2014. https://dl.acm.org/doi/10.1145/2588555.2610507
[21] Crotty, Leis, Pavlo, "Are You Sure You Want to Use MMAP in Your Database Management System?," CIDR 2022. https://db.cs.cmu.edu/papers/2022/cidr2022-p13-crotty.pdf
[22] SQLite, "Query Optimizer Overview" (covering indexes, two binary searches). https://sqlite.org/optoverview.html
[23] SQLite, "The WITHOUT ROWID Optimization." https://sqlite.org/withoutrowid.html
[24] PostgreSQL, "Index-Only Scans and Covering Indexes." https://www.postgresql.org/docs/current/indexes-index-only-scans.html
[25] PostgreSQL, "Using EXPLAIN" (bitmap heap scans). https://www.postgresql.org/docs/current/using-explain.html
[26] SQLite, "The Virtual Database Engine / Opcodes." https://www.sqlite.org/opcode.html
[27] PostgreSQL wiki, "Hash Join." https://wiki.postgresql.org/wiki/Hash_Join
[28] SQLite, "The Next-Generation Query Planner." https://sqlite.org/queryplanner-ng.html
[29] SQLite, "ANALYZE." https://sqlite.org/lang_analyze.html
[30] Raasveldt, Mühleisen, "DuckDB: an Embeddable Analytical Database," SIGMOD 2019. https://duckdb.org/pdf/SIGMOD2019-demo-duckdb.pdf

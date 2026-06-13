# ADSQL Roadmap

A pure-Swift, SQLite-compatible embedded database engine for macOS. This file
is the single source of truth for milestone status, performance headroom, the
deferred-SQL registry, and the consumer (apple-docs) dependency. Design
rationale lives in `docs/rfcs/`; active multi-milestone execution (M5 → M7) is
scheduled in `docs/rfcs/0008-execution-schedule.md` — the live program tracker.

## Milestone suite

| Milestone | Status | Scope |
|---|---|---|
| **M0–M2 — Storage kernel** | ✅ done | COW B+tree over reserve-max mmap (16 KiB pages, XXH64-checksummed); single-writer / wait-free-reader MVCC; free-list reclamation; commit protocol (one F_BARRIERFSYNC + meta ping-pong) with crash-injection recovery; cross-process reader table + writer lock; group commit. |
| **M3 — Relational layer** | ✅ done | Strict typed `Value`/columns; order-preserving `KeyCodec`; `RecordCodec`; catalog + transactional DDL; DML with conflict policies and secondary-index maintenance; FK `ON DELETE CASCADE/RESTRICT`; deep integrity (index ⇄ row bijection). |
| **M4 — SQL front end** | ✅ done | Lexer → parser → binder → heuristic planner → row-at-a-time executor → writer. Single-table & joined SELECT, WHERE/projection/ORDER BY/LIMIT/OFFSET/DISTINCT, INNER/LEFT joins, GROUP BY + COUNT/SUM + HAVING, UNION/UNION ALL, INSERT/UPDATE/DELETE + RETURNING, DDL. Differential-tested vs CSQLite. See `docs/rfcs/0001-sql-engine.md`. |
| **M4.5 — SQL completeness** | ✅ done | PRAGMA compatibility, BETWEEN, INSERT…SELECT, `ON CONFLICT DO UPDATE` (upsert), correlated scalar subqueries, `db.transaction { }`. |
| **M4.6 — Scan-engine performance** | ✅ done | Zero-copy row decode (no per-row record copy) + bounded top-N + drop residual conjuncts an exact index probe already covers. Took `sql search` 14.3 → 5.34 ms. See `docs/rfcs/0002-scan-engine-performance.md`. |
| **M4.7 — Perf + memory-safety pass** | ✅ done | Perf: B7 ordered rowid fetch (warm `Cursor.seekForward`, 5.34 → ~5.0 ms), B1 incremental decode, B3 positional `insertAssembled`, A4 relational lazy `RowView` scan (index scan ~2×). Safety: **`-strict-memory-safety` enabled module-wide** (SE-0458) — every unsafe construct marked `unsafe` or `@safe`-encapsulated, perf-neutral. See `docs/rfcs/0003-…`. |
| **M4.8 — Query-engine performance** | ✅ done | `SELECT DISTINCT` O(n²)→O(n) (GroupKey); index-nested-loop join (the O(M·N) S1 bug → O(M·logN)); write-path `Array(s.utf8)` allocs dropped; **column references bound to `(table,column)` slots at bind time** — removes the per-row `binding.resolve` `lowercased()` string resolution the profiling fingered (`sql search` ~10%, `distinct` ~17%, `join` ~20%). Profiling re-attributed gap (b): the descent/fetch is competitive; the residual is the per-row tree-walk interpreter (a future VDBE-style flat loop). Hash join + persisted `ANALYZE` deferred (low value for an FK-indexed search DB). See `docs/reviews/0002-…`, `docs/rfcs/0004-…`. |
| **M5 — FTS + bm25/bm25f** | 🚧 in progress | First-class full-text search: `CREATE VIRTUAL TABLE … USING fts5`, `MATCH`, `bm25()`/**bm25f** custom weights, porter/unicode61 + trigram tokenizers, block-max WAND top-k, general `CREATE TRIGGER` sync. Same on-disk format (version-bumped). **The apple-docs migration blocker.** Act I of the two-act program (RFC 0008); phases F0–F6. See `docs/rfcs/0007-fts-and-ranking.md`. (Vector search is app-side — see below — so M5 is effectively FTS5.) |
| **M6 — Hardening + importer** | ⏳ queued | Expanded fuzz/crash-injection coverage, a SQLite-file importer (loose→strict type coercion), and operational polish. Not part of the M5→M7 program (RFC 0008); the FTS format-version bump + crash-injection feed it. |
| **M7 — Query DSL & metaprogramming** | ⏳ planned | Type-safe, injection-safe query DSL lowering to the public AST via a `prepare(ast:)` seam (result builder + operators, dependency-free); macro tier (`#SQL`, `@Table`, `@dynamicMemberLookup`, `@FixedLayout`) on a **scoped** `swift-syntax` `.macro` plugin (kernel stays zero-dep). Act II of the two-act program (RFC 0008); phases P0–P2, gated on M5/F5. See `docs/rfcs/0006-swift-metaprogramming-and-dsl.md`. |

## Performance headroom

Benchmarks (`swift run -c release ADSQLBench`, 100k rows, M-series, vs system
SQLite in WAL with apple-docs pragmas). ADSQL **leads** on the read-mostly
paths and trails on filtered scans and inserts:

| Scenario | ADSQL | SQLite | Δ | Status |
|---|---|---|---|---|
| cold open → first get | 49 µs | 245 µs | **5×** | ✓ |
| point get (p50) | 0.8 µs | 2.9 µs | **3.6×** | ✓ |
| raw KV scan | 4935 MB/s | 4039 MB/s | **1.2×** | ✓ |
| 16 concurrent readers | 1.07 M/s | 0.47 M/s | **2.3×** | ✓ |
| rowid get (p50) | 0.8 µs | 2.2 µs | **2.75×** | ✓ |
| **`sql search` (filter + ORDER BY/LIMIT)** | ~~14.3~~ → ~~5.34~~ → ~~5.0~~ → **~4.6 ms** | 1.76 ms | ~~0.12×~~ → **~0.38×** | M4.6 + M4.7/B7 + M4.8 (slot binding) |
| **relational index scan** | ~~1.23~~ → **~2.2 M/s** | ~3.1 M/s | ~~0.35×~~ → **~0.69×** | M4.7/A4 ✓ (lazy `RowView`, ~2×) |
| **batch insert (SQL / 3-index)** | ~138 → ~143 → **~147 k/s** | ~224 k/s | **~0.66×** | M4.7/B3 + M4.8 (utf8 alloc dropped) |
| batch insert (relational / 5-index) | ~118 → **~125 k/s** | 159 k/s | **~0.79×** | M4.8 (NOCASE double-copy removed) |
| **`SELECT DISTINCT` (dup-heavy)** | ~~O(n²) (unrunnable)~~ → ~~74~~ → **~61 ms** | 4.6 ms | **0.08×** | M4.8 (O(n) GroupKey + slot binding; residual = full materialize + no index-distinct) |
| **`sql join` (indexed equi-join)** | ~~O(M·N) (unrunnable)~~ → ~~240~~ → **~178 ms** | 21.7 ms | **0.12×** | M4.8/INLJ + slot binding (residual = per-row tree-walk interpreter) |
| **filtered scan / index scan / join residual** | — | — | — | gap (b) re-attributed → per-row column re-resolution + tree-walk; lever = bind columns to slots (M4.8 next) |

What closes each gap:

- **Filtered scan / search (M4.6 ✓).** Three executor changes took it from
  14.3 ms to 5.34 ms: (1) **zero-copy decode** — `RowSlot` reads columns
  straight from the mapped page span (`BTree.ValueRef.inline`) instead of
  copying the whole record per row; (2) **bounded top-N** — an unordered
  ORDER BY + small LIMIT keeps only `offset+limit` rows instead of
  materializing and sorting every match; (3) **residual elimination** — the
  conjuncts an exact index/rowid probe already guarantees are dropped from the
  WHERE residual. The residual ~3× gap that remains is the per-row
  index→table descent (shared with SQLite) plus `RecordCodec.cellOffsets`
  walking/allocating the full offset table to read one sort-key column — a
  candidate for incremental single-column decode.
- **Relational index scan (M4.7/A4 ✓).** Added `RowView` (noncopyable, lazy)
  + `RowCursor.forEachRow`, layered on the zero-copy `forEachRecordSpan`, so a
  scan decodes only the columns it touches — no per-row `Row` + names array.
  ~0.35× → ~0.69× (≈2×). The eager `next()`/`Row` API stays.
- **Insert (M4.7/B3, partial).** `Relation.insertAssembled` (ordered `[Value]`,
  no per-row dict) is built and used by `Writer.insert`. Removed the string
  hashing, but `sql insert` barely moved (~0.64×): the four B+tree COW inserts
  per row (table + 3 indexes) dominate, not row assembly. The real lever is the
  **B+tree write path** (page COW / split / free-list) — a future perf item.
- **Joins / correlated subqueries (deferred).** Inner/sub table is full-scanned
  per outer row (nested loop, no index probe). Fix: push the ON-equality /
  correlated predicate into an index probe (O(M·N) → O(M·log N)).
- **Memory safety (M4.7 ✓).** `-strict-memory-safety` is on for the kernel: the
  compiler now flags any new unsafe construct that isn't marked `unsafe` or
  encapsulated by a `@safe` type. Perf-neutral. A future refinement is the
  `@safe` Page-wrapper refactor (threading a safe page type through the B+tree
  core to shrink the marked surface) — see RFC 0003.

## Deferred SQL constructs

Parsed-and-rejected today with named `sqlUnsupported` errors (not bugs —
explicit scope boundaries):

- **M5 (FTS) — 🚧 in progress (RFC 0007, scheduled by RFC 0008):**
  `CREATE VIRTUAL TABLE`, `MATCH`, `bm25()`, and general `CREATE TRIGGER` (the FTS
  sync mechanism) are being un-rejected phase-by-phase (F0–F6). Live state: the
  status table in `docs/rfcs/0008-execution-schedule.md`.
- **Subqueries:** `EXISTS`, FROM-clause subqueries, `IN (SELECT …)` beyond the
  `json_each` shape, compound scalar subqueries.
- **Aggregates:** `AVG`/`MIN`/`MAX`/`TOTAL`/`GROUP_CONCAT`, `COUNT(DISTINCT …)`.
- **Query:** CTEs (`WITH`), window functions, `EXCEPT`/`INTERSECT`,
  `NATURAL`/`RIGHT`/`FULL`/`CROSS`/comma joins, `JOIN … USING`,
  `SELECT` without `FROM`.
- **Operators:** `GLOB`/`REGEXP`, `LIKE … ESCAPE`, `IS` beyond `IS [NOT] NULL`.
- **DDL/DML:** `ALTER TABLE`, `CREATE VIEW` (general `CREATE TRIGGER` → M5/F5), partial indexes, `DESC`
  index columns, `WITHOUT ROWID`, `PRIMARY KEY DESC`, `ON DELETE` actions
  beyond `CASCADE`/`RESTRICT`, `DEFAULT` exprs other than `datetime('now')`,
  `ON CONFLICT … DO UPDATE … WHERE`.
- **Other:** `PRAGMA` is accepted-but-mostly-no-op (durability is governed by
  `DatabaseOptions`); `EXPLAIN`/`VACUUM` rejected.

## Non-goals

- SQLite's loose/dynamic typing — ADSQL columns are STRICT; coercion happens
  only at explicit boundaries (`CAST`, the M6 importer).
- `EXPLAIN`, `VACUUM`, views, `ALTER TABLE` (beyond what the importer needs).
  (General `CREATE TRIGGER` is **in scope** as M5's FTS-sync mechanism — RFC 0007 F5.)
- Non-macOS platforms (Apple Silicon first; 16 KiB native pages).
- Third-party **runtime** dependencies (zero). Amended (RFC 0008 D2): the M7 macro
  tier adopts `swift-syntax`, **scoped to a compile-time-only `.macro` plugin target**
  (`ADSQLMacros`); `ADSQLKernel` and every shipping artifact stay zero-dep.

## Consumer dependency (apple-docs / RFC 0001 P5)

ADSQL exists to replace the `bun:sqlite` layer of the apple-docs offline index.
Its migration step (P5) is search-centric:

- The runtime search is a 4-tier cascade — **FTS5 `bm25`** (custom weights),
  case-insensitive title-exact, **trigram** fuzzy, and an opt-in body FTS — so
  **FTS5 + the trigram tokenizer are the hard blocker (M5).**
- **Vector search is not a SQL feature:** embeddings are `BLOB` columns
  (`document_chunks.vec_bin`/`vec_i8`); the Hamming shortlist + int8 rescore run
  in application code over those bytes. ADSQL needs fast BLOB scans + batched
  `IN` fetches (already supported), not a native vector index — which is why M5
  is effectively just FTS5.
- The connection-setup pragmas, `json_each`/`json_extract`, `NOCASE`, and the
  search/listing/facet query shapes are already covered and differential-tested
  (`Tests/ADSQLKernelTests/SQLAcceptanceTests.swift`).

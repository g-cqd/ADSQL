# ADSQL Roadmap

A pure-Swift, SQLite-compatible embedded database engine for macOS. This file
is the single source of truth for milestone status, performance headroom, the
deferred-SQL registry, and the consumer (apple-docs) dependency. Design
rationale lives in `docs/rfcs/`.

## Milestone suite

| Milestone | Status | Scope |
|---|---|---|
| **M0–M2 — Storage kernel** | ✅ done | COW B+tree over reserve-max mmap (16 KiB pages, XXH64-checksummed); single-writer / wait-free-reader MVCC; free-list reclamation; commit protocol (one F_BARRIERFSYNC + meta ping-pong) with crash-injection recovery; cross-process reader table + writer lock; group commit. |
| **M3 — Relational layer** | ✅ done | Strict typed `Value`/columns; order-preserving `KeyCodec`; `RecordCodec`; catalog + transactional DDL; DML with conflict policies and secondary-index maintenance; FK `ON DELETE CASCADE/RESTRICT`; deep integrity (index ⇄ row bijection). |
| **M4 — SQL front end** | ✅ done | Lexer → parser → binder → heuristic planner → row-at-a-time executor → writer. Single-table & joined SELECT, WHERE/projection/ORDER BY/LIMIT/OFFSET/DISTINCT, INNER/LEFT joins, GROUP BY + COUNT/SUM + HAVING, UNION/UNION ALL, INSERT/UPDATE/DELETE + RETURNING, DDL. Differential-tested vs CSQLite. See `docs/rfcs/0001-sql-engine.md`. |
| **M4.5 — SQL completeness** | ✅ done | PRAGMA compatibility, BETWEEN, INSERT…SELECT, `ON CONFLICT DO UPDATE` (upsert), correlated scalar subqueries, `db.transaction { }`. |
| **M4.6 — Scan-engine performance** | ▶ active | Zero-copy row decode (no per-row record copy) + drop residual conjuncts an exact index probe already covers. Closes the filtered-scan headroom below. See `docs/rfcs/0002-scan-engine-performance.md`. |
| **M5 — FTS + vector indexes** | ⏳ next | First-class full-text search: FTS5 virtual tables, `MATCH`, `bm25()` with custom weights, porter/unicode61 + trigram tokenizers, sync triggers. Same on-disk format. **The apple-docs migration blocker.** (Vector search is app-side — see below — so M5 is effectively FTS5.) |
| **M6 — Hardening + importer** | ⏳ queued | Expanded fuzz/crash-injection coverage, a SQLite-file importer (loose→strict type coercion), and operational polish. |

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
| **`sql search` (filter + ORDER BY/LIMIT)** | 14.3 ms | 1.76 ms | **0.12× (8.2× slower)** | → M4.6 |
| **relational index scan** | 1.23 M/s | 3.53 M/s | **0.35×** | → M4.6 |
| **batch insert (SQL / 3-index)** | 138 k/s | 222 k/s | **0.62×** | → write-path pass (deferred) |
| batch insert (relational / 5-index) | 118 k/s | 159 k/s | 0.75× | → write-path pass (deferred) |

What closes each gap:

- **Filtered scan / search (M4.6).** `RowCursor.nextRecord` copies the whole
  record into a fresh `[UInt8]` per scanned row (`Rows.swift`), and the
  executor re-evaluates predicates an exact index probe already guarantees.
  Fix: decode directly from the mmap page span (`ValueRef.inline`), drop
  covered residual conjuncts.
- **Insert (deferred write-path pass).** `assembleRow`/`Writer.insert` build a
  fresh `[String: Value]` dictionary per row. Fix: the never-built
  `Relation.insertAssembled` (ordered `[Value]`, no dict), bound once.
- **Joins / correlated subqueries (deferred).** Inner/sub table is full-scanned
  per outer row (nested loop, no index probe). Fix: push the ON-equality /
  correlated predicate into an index probe (O(M·N) → O(M·log N)).

## Deferred SQL constructs

Parsed-and-rejected today with named `sqlUnsupported` errors (not bugs —
explicit scope boundaries):

- **M5 (FTS):** `CREATE VIRTUAL TABLE`, `MATCH`, `bm25()`.
- **Subqueries:** `EXISTS`, FROM-clause subqueries, `IN (SELECT …)` beyond the
  `json_each` shape, compound scalar subqueries.
- **Aggregates:** `AVG`/`MIN`/`MAX`/`TOTAL`/`GROUP_CONCAT`, `COUNT(DISTINCT …)`.
- **Query:** CTEs (`WITH`), window functions, `EXCEPT`/`INTERSECT`,
  `NATURAL`/`RIGHT`/`FULL`/`CROSS`/comma joins, `JOIN … USING`,
  `SELECT` without `FROM`.
- **Operators:** `GLOB`/`REGEXP`, `LIKE … ESCAPE`, `IS` beyond `IS [NOT] NULL`.
- **DDL/DML:** `ALTER TABLE`, `CREATE VIEW`/`TRIGGER`, partial indexes, `DESC`
  index columns, `WITHOUT ROWID`, `PRIMARY KEY DESC`, `ON DELETE` actions
  beyond `CASCADE`/`RESTRICT`, `DEFAULT` exprs other than `datetime('now')`,
  `ON CONFLICT … DO UPDATE … WHERE`.
- **Other:** `PRAGMA` is accepted-but-mostly-no-op (durability is governed by
  `DatabaseOptions`); `EXPLAIN`/`VACUUM` rejected.

## Non-goals

- SQLite's loose/dynamic typing — ADSQL columns are STRICT; coercion happens
  only at explicit boundaries (`CAST`, the M6 importer).
- `EXPLAIN`, `VACUUM`, triggers, views, `ALTER TABLE` (beyond what the importer
  needs).
- Non-macOS platforms (Apple Silicon first; 16 KiB native pages).
- Third-party dependencies (zero).

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

# RFC 0001 — SQL Engine (M4 / M4.5)

Status: implemented. This is the design of record for ADSQL's SQL front end:
how a SQL string becomes results over the M3 relational layer, and the
invariants that keep it SQLite-faithful.

## Goals

- A SQLite-compatible SQL subset — exactly the surface the apple-docs consumer
  uses — with **bit-identical results** to real SQLite, proven by differential
  testing rather than asserted.
- Zero new on-disk format; the SQL layer sits entirely on top of M3
  (`Relation`, `TxnContext`, `Catalog`, `RowCursor`).
- A public API shaped like `bun:sqlite` for an easy consumer port.

## Pipeline

```
SQL text → Lexer → Parser → AST → Binder → (Planner) → Executor / Writer → rows
```

- **Lexer / Parser / AST** (`SQL/Lexer.swift`, `Parser.swift`, `AST.swift`) —
  recursive-descent over the SQLite subset; constructs outside the subset fail
  with named `sqlUnsupported` errors (see ROADMAP's deferred registry). `prepare`
  lexes + parses only (no schema).
- **Binder** (`SQL/Plan.swift`) — resolves a parsed statement against a schema
  *version*: table/column resolution across FROM/JOIN tables (`QueryBinding`),
  `*` expansion, output naming, aggregate rewrite (COUNT/SUM → internal
  `aggregateResult` slots), GROUP BY/ORDER BY/compound resolution. A `Statement`
  caches one bound plan per **catalog version**, so a DDL commit transparently
  rebinds.
- **Planner** (`SQL/Planner.swift`) — heuristic access-path selection (below).
- **Executor** (`SQL/Executor.swift`) — row-at-a-time, generic over
  `PageResolver` (works over a read snapshot or a write txn's overlay):
  access-path source → WHERE → projection → DISTINCT → ORDER BY → OFFSET/LIMIT;
  nested-loop joins; hash GROUP BY/DISTINCT/UNION via `GroupKey`.
- **Writer** (`SQL/Writer.swift`) — INSERT (VALUES / OR REPLACE-IGNORE / ON
  CONFLICT DO UPDATE / RETURNING / INSERT…SELECT), two-phase UPDATE/DELETE,
  DDL. Reuses M3 `Relation` DML.

## Planner contract: superset + residual

The planner is an optimization, never a source of truth. **Every access path it
chooses is a superset of the rows the predicate accepts, and the executor
re-applies the full original WHERE as a residual.** Consequences:

- A converted/widened probe (e.g. int↔real boundary coercion) can over-return;
  the residual filters it.
- A correlated predicate is simply a non-constant, hence non-sargable; it stays
  in the residual (full scan of the inner relation) — see correlated subqueries.
- Paths: rowid point/IN → unique/index equality-prefix (+1 trailing range) →
  index IN → full scan. Order-by-satisfied-by-index enables sort skip + LIMIT
  early-exit. `Statement.planDescription()` exposes the choice for assertions.

This contract is what makes the differential fuzz decisive: `SQLPlannerResidualTests`
runs random queries three ways — indexed ADSQL, unindexed ADSQL (planner
invariance), and SQLite (semantics) — and requires all three to agree.

(M4.6 refines this: when a probe is an *exact* equality cover, the covered
conjuncts may be dropped from the residual — see RFC 0002.)

## Exact-SQLite semantics

Implemented in `SQL/Eval.swift` / `Functions.swift` and validated against
CSQLite:

- **Three-valued logic** everywhere (AND/OR/NOT; `x IN (…, NULL)`; NOT IN with
  NULL never TRUE).
- **`SQLCompare`** — lossless INTEGER↔REAL comparison (correct at the 2^53
  boundary and beyond, `−0.0 == 0.0`, computed NaN behaves like NULL); never
  reuses the index byte order. Text compares the UTF-8 views directly (no
  per-comparison allocation), matching SQLite BINARY; NOCASE folds ASCII.
- **Type affinity in comparisons** — a CAST/column with numeric affinity
  converts a well-formed numeric TEXT operand before comparing.
- **Arithmetic** — integer overflow promotes to REAL; `/0`→NULL; `%` int-casts
  (saturating) with a REAL result if either input is REAL.
- **Functions** — LOWER/UPPER/LENGTH/INSTR/SUBSTR (1-based, char semantics),
  COALESCE, CAST, `||`, CASE, `%.15g` real formatting with round-trip upgrade,
  a minimal JSON parser (`json_extract`/`json_each`), `datetime('now')`.
- **Collation resolution** — explicit COLLATE > left column > right column >
  BINARY; LIKE is ASCII-case-insensitive.

## Aggregation & grouping

`GroupKey` (`SQL/Grouping.swift`) canonicalizes a value tuple for GROUP BY,
DISTINCT, and UNION dedup: integral REAL folds to INTEGER (so 1 and 1.0 group),
NOCASE text is folded, NULLs are equal — matching SQLite grouping while keeping
`Value` non-Hashable. SUM skips NULLs, promotes to REAL on a real input, returns
NULL for an empty group, and raises on Int64 overflow; COUNT(*) counts rows
while COUNT(expr) counts non-NULLs.

## Correlated scalar subqueries

Correlation is resolved entirely at execution, with no binder change: the
executor's row environment gains an **outer (context, binding) fallback**, so a
subquery column absent from its own tables resolves against the current outer
row. A recursive `SubqueryRunner` (supplied by the statement layer, capturing
only Copyable snapshot handles — never the noncopyable txn) binds the subquery
against the same snapshot and returns the first row's first column (NULL when
empty). The correlated predicate is non-sargable, so today the inner relation
is full-scanned per outer row (an index-probe optimization is deferred).

## Public API

`db.prepare(sql) -> Statement`; `Statement.run/all/get` with positional `?` or
named `$name`/`:name` params; `RunResult{changes, lastInsertRowid}`; `SQLRow`
over a shared column header; `db.transaction { tx in tx.run(…) }` for batched
writes (commit-once or all-rollback). Reads run in a snapshot; writes in one
exclusive transaction. A parse cache (LRU by SQL text) makes re-prepare cheap.

## Acceptance method

Differential vs the system SQLite (`CSQLite`, test target only): a `SQLiteMirror`
runs the same DDL/DML/queries and results are compared (ordered under ORDER BY,
else multiset). Coverage: the apple-docs literal corpus (search/listing/facet),
per-feature suites, and cross-feature fuzzers (thousands of generated queries).
This is the gate — a feature is "done" when ADSQL and SQLite agree.

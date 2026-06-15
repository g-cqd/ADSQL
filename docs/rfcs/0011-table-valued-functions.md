# RFC 0011 — Table-valued functions (`json_each` / `json_tree`)

**Status:** Proposed (design only — no code yet) · **Area:** SQL front end (parser → binder → planner → executor) · **Depends on:** the ADJSON-backed JSON layer (`SQLJSON`, `SQLiteJSONPath`) already landed.
**Goal:** support SQLite's `json_each(doc[,path])` and `json_tree(doc[,path])` as real `FROM` sources exposing the columns `key, value, type, atom, id, parent, fullkey, path`, including correlated use (`FROM docs, json_each(docs.meta)`). This is the one remaining gap to full SQLite JSON1 parity; it requires a **general table-valued-function (TVF)** seam, which `json_each`/`json_tree` are the first (and, for now, only) instances of.

> `ROADMAP.md` §3E lists FROM-clause table functions among the deferred SQL surface. This RFC owns the design detail; ROADMAP owns the priority. State claims (PRESENT/ABSENT) are grounded in cited source files.

---

## 1. Why

The scalar/operator/aggregate JSON1 surface is complete and differentially tested against system SQLite: `json_extract` (multi-path), `->`/`->>`, `json_type`, `json_valid`, `json_array_length`, `json_quote`, `json`, `json_array`, `json_object`, `json_set`/`insert`/`replace`/`remove`, `json_patch`, `json_group_array`, `json_group_object`.

The **only** remaining JSON1 feature is row-producing iteration. Today `json_each` exists **only** in the contracted predicate shape `x IN (SELECT value FROM json_each(<expr>))` — parsed in `Parser+Expr.swift` `inSuffix()` into `SQLExpr.inJSONEach` (`AST.swift`) and evaluated as a per-row boolean in `Eval.swift` via `SQLJSON.eachValues`. It is **not** a `FROM` source: it cannot project `key`, `value`, `type`, …, cannot be joined, and `json_tree` does not exist at all.

Full parity requires `SELECT key, value FROM json_each(:doc)` and correlated `SELECT j.value FROM docs, json_each(docs.meta) AS j`.

## 2. Goal & non-goals

**In scope**
- A general TVF seam in the FROM clause: `name(arg, …) [AS alias]`.
- `json_each(doc[, path])` and `json_tree(doc[, path])` with the 8 SQLite columns.
- Correlated arguments (TVF args may reference earlier tables in the FROM/JOIN list).
- Differential parity with system SQLite on `key/value/type/atom/fullkey/path` and parent-linkage structure.

**Out of scope (deferred, unchanged)**
- General FROM-subqueries / CTEs (still parsed-and-rejected per ROADMAP §3E). A TVF is *structurally simpler* than a subquery (it produces rows directly, with a fixed synthetic schema, no nested binder/planner), so it does not unblock or require them.
- User-defined TVFs. The registry is closed to `json_each`/`json_tree`.
- Byte-matching SQLite's exact `id` integers (implementation-defined — see §5).

## 3. Current architecture (grounded)

The pipeline is **lexer → parser → binder → heuristic planner → row-at-a-time executor** (ROADMAP §1). The integration points:

- **AST** (`SQL/AST.swift`): `SQLSelect.from: SQLTableRef?` + `joins: [SQLJoin]`; `SQLTableRef` is `{ name, alias, offset }` — a **bare table name only**, no function-call notion. `SQLResultColumn` for projections.
- **Parser** (`SQL/Parser.swift`): `selectCore()` parses `FROM`, and **explicitly rejects** `(` after FROM (`"subqueries in FROM"`). `tableRef()` reads `identifier [AS alias]` only.
- **Binder** (`SQL/Binder.swift`, `Binder+Binding.swift`, `Plan.swift`): `bind(_ reference: SQLTableRef) -> TableBinding` resolves against `schema.tables`, with a **precedent for synthetic sources**: FTS5 tables aren't in `schema.tables` and bind against `syntheticFTSDefinition(name)` with `isFTS: true`. `QueryBinding.resolve(qualifier:name:) -> (table: Int, column: Int)?` maps a column reference to a `(depth, columnIndex)` slot; `bindColumns` rewrites `.column` → `.boundColumn`. Unresolved columns stay `.column` for outer/correlated lookup.
- **Planner** (`SQL/Planner.swift`, `Plan.swift`): `AccessPlan` ∈ `{ tableScan, rowid, index, fts }`. `.fts(table, query, weights)` is the **non-btree precedent** — an access path whose row stream is produced from an evaluated expression, not a B-tree cursor.
- **Executor + row model** (`SQL/Executor.swift`, `JoinExecutor.swift`, `ResultPipeline.swift`, `RowSlot.swift`): `RowSource` ∈ `{ table, rowids, index, fts }`. `resolveAccess` turns an `AccessPlan` into a `RowSource` (evaluating expressions against the live `env`, exactly as `.fts` evaluates its MATCH query). `forEachRow` enumerates a source and calls `body(rowid, span, score)`; `RowContext` holds one `RowSlot` per table; `RowSlot.value(at:)` lazily decodes columns from a record byte-span, **except** FTS, where `rowid`/`rank` are synthesized without a span. `JoinExecutor.forEachFilteredRow` is a nested-loop driver that re-resolves each inner source per outer row — the hook correlated TVF args need.

**Assessment:** FTS proves the engine can carry a non-btree, expression-driven row source whose columns are synthesized rather than decoded. A TVF is the same shape, but must expose *several* real columns (not just rowid/rank) generated on the fly. Tractable; spans 4 layers (~1.2–1.8k LOC + tests).

## 4. Design

### 4.1 The synthetic schema

Both functions expose the SQLite column order:

| col | json_each | json_tree |
|---|---|---|
| `key` | array index (INTEGER) or object label (TEXT) of the element within its parent; NULL at a primitive root | same |
| `value` | the element, SQLite-mapped (objects/arrays → JSON text) — reuse `SQLJSON.toSQL` | same |
| `type` | `SQLJSON.typeName` (null/true/false/integer/real/text/array/object) | same |
| `atom` | `value` if primitive, else NULL | same |
| `id` | monotonic per-row integer (see §5) | same |
| `parent` | NULL (json_each is one level deep) | `id` of the containing node, NULL at the walk root |
| `fullkey` | SQLite path from `$` to this element (`$.a[0]`) | same |
| `path` | SQLite path to this element's **parent/container** (`$`, `$.a`) | same |

`json_each` enumerates the **immediate children** of the node selected by `path` (default `$`): array → one row per element; object → one row per member; primitive → one row (`key` NULL). `json_tree` is the **recursive** depth-first walk of that subtree, emitting the selected node itself first, then all descendants.

The generators reuse the existing ADJSON primitives: `JSON.forEachElement`/`forEachMember` (now public), `SQLiteJSONPath` for the optional `path` argument, and `SQLJSON.toSQL`/`typeName`/`render` for the value/type/atom columns — so integer/real fidelity and the documented value-mapping are inherited for free.

### 4.2 AST (`SQL/AST.swift`)

Introduce a table-source sum type rather than overloading `SQLTableRef`:

```
enum SQLTableSource: Equatable, Sendable {
    case table(SQLTableRef)
    case function(name: String, args: [SQLExpr], alias: String?, offset: Int)
}
```

`SQLSelect.from` becomes `SQLTableSource?` and `SQLJoin.table` becomes `SQLTableSource`. This keeps the common base-table path untouched (it stays `.table(SQLTableRef)`) and isolates the new shape. The args are ordinary `SQLExpr` (no new expression nodes).

### 4.3 Parser (`SQL/Parser.swift`, `Parser+Expr.swift`)

In `tableRef()` (rename to `tableSource()`), after reading the leading identifier, if the next token is `(`, parse a comma-separated `expression()` list and the optional `AS alias` → `.function(name, args, alias, offset)`; otherwise the existing `.table(SQLTableRef)`. Remove the blanket "subqueries in FROM" rejection only for the `name(` case (a leading `( SELECT` stays rejected). Arg expressions reuse the existing grammar — including column refs for correlation. The existing contracted `inJSONEach` parse path is left intact (§7).

### 4.4 Binder (`SQL/Binder.swift`, `Binder+Binding.swift`)

- A small **TVF registry** (parallel to `schema.ftsTables`): name → `{ columnNames, columnTypes, arity }`. Closed set: `json_each`, `json_tree`.
- `bind(_ source: SQLTableSource)`: for `.function`, look up the registry and build a synthetic `TableBinding` (the 8 columns, `binding = alias ?? name`, `isFTS = false`, no indexes/rowid) — mirroring `syntheticFTSDefinition`. Store the bound arg expressions on the bound source.
- **Correlated args:** bind the arg `SQLExpr`s with the *prefix* binding (tables strictly before this source in the FROM/JOIN order), exactly as `JoinEqualities`/`referencesOnlyBelow` already scope join ON-values. An arg referencing a later/!visible table is a bind error.
- Column refs to the TVF's columns (`j.value`, bare `value`) resolve through the normal `QueryBinding.resolve` → `.boundColumn(depth, colIndex)` path with no special-casing.

### 4.5 Planner (`SQL/Planner.swift`)

Add `case tableFunction(name: String, args: [SQLExpr])` to `AccessPlan`. A TVF source always plans to `.tableFunction` (no index/rowid/scan choice; WHERE predicates over its columns become residual filters, like any non-sargable source). Natural order = document order; it satisfies an `ORDER BY` only when there is none (conservative, matching `.fts`).

### 4.6 Executor + row model (`SQL/Executor.swift`, `JoinExecutor.swift`, `RowSlot.swift`, `ResultPipeline.swift`)

- Add `case tableFunction(generator)` to `RowSource`. `resolveAccess` evaluates the arg `SQLExpr`s against the **current `env`** (which, inside the nested-loop driver, already exposes outer-table columns — the correlation hook) and constructs the row generator.
- The generator is an **eager materialization** of the synthetic rows for this argument binding: a `[[Value]]` (8 columns × N rows) produced by walking the parsed JSON once (`json_each` = one level; `json_tree` = recursive DFS with an `id`/`parent` counter). Eager is acceptable — a JSON document is already fully in memory, and it keeps the row model simple (no streaming cursor over the tape).
- A synthetic `RowSlot` variant returns `row[columnIndex]` directly (computed values, no byte-span decode) — the same "no real span" situation FTS already handles for `rowid`/`rank`, generalized to N columns.
- `forEachRow`/`forEachFilteredRow`: enumerate the materialized rows, calling `body` with a synthetic monotonic rowid; the nested-loop join re-resolves (re-evaluates args, re-materializes) per outer row, giving correlation for free.

### 4.7 Reused JSON primitives

No new JSON parsing. `json_each`/`json_tree` generation is a new ~120-line file (e.g. `SQL/JSONTable.swift`) on top of `ADJSON.parse` + `SQLiteJSONPath.evaluate` + `forEachElement`/`forEachMember` + `SQLJSON.toSQL`/`typeName`/`render`.

## 5. Semantics details & known divergences

- **`id` / `parent` are implementation-defined.** SQLite numbers them by JSONB/tape offset; we assign a monotonic document-order counter, with `parent` the counter of the containing node (json_tree) or NULL (json_each). The **structure** (parent linkage, row count, ordering) matches SQLite; the **raw integers do not**. Differential tests must compare `key/value/type/atom/fullkey/path` and the parent *relationships*, not raw `id` values. (Documented divergence, in the spirit of the existing JSON-subtype note.)
- **`path` vs `fullkey`:** `path` is the container path, `fullkey` includes the final key/index. Both use SQLite path syntax and reuse the dialect already in `SQLiteJSONPath`.
- **Two-arg form** `json_each(doc, '$.a')` roots the walk at the path target; a path that doesn't resolve yields **zero rows** (not an error), matching SQLite.
- **Malformed JSON** is a runtime error (consistent with `json_extract` post-rewrite).
- **`key` column type** is polymorphic (INTEGER for array indices, TEXT for object labels) — fine under the dynamic `Value`.

## 6. Phasing (strategy-beside discipline, one concern per commit)

1. **AST + parser** — `SQLTableSource`, `tableSource()`, function-source parsing; round-trip parse tests. (No execution yet; binder rejects `.function` with `sqlUnsupported` so the build stays green.)
2. **Binder + synthetic schema + registry** — bind `json_each`/`json_tree` to the 8-column synthetic table; correlated-arg scoping; column resolution tests.
3. **Planner + executor + row model** — `AccessPlan.tableFunction`, `RowSource.tableFunction`, synthetic `RowSlot`, the `json_each` generator (one level). Differential tests vs SQLite for `json_each` (uncorrelated + correlated).
4. **`json_tree`** — recursive generator + `id`/`parent` linkage. Differential tests (structure-level).
5. **Cleanup** — optionally re-express the contracted `inJSONEach` as sugar over the new source (or keep it as a fast path; §7), and move the ROADMAP entry from §3E deferred to done.

Each phase builds, passes `swift test`, and runs the concurrency/crash gates per ROADMAP §4.

## 7. Interaction with the existing `inJSONEach`

`SQLExpr.inJSONEach` (the `x IN (SELECT value FROM json_each(…))` predicate) is **independent** of this work and can stay as a fast path (it avoids the join machinery for a pure membership test). Once the FROM source exists, `inJSONEach` could be lowered to `x IN (SELECT value FROM <tvf source>)` and deleted, but that is an optional simplification, not a requirement. No conflict either way.

## 8. Testing

- **Differential vs system SQLite**, reusing the table-based harness in `SQLAggregateTests` (`SQLiteMirror` + `rowsMatch`): `SELECT key,value,type,atom,fullkey,path FROM json_each(:doc)` over arrays/objects/nested/primitive docs; the two-arg path form; correlated `FROM t, json_each(t.col)`; `json_tree` structural walks. **Exclude raw `id`** from comparisons (assert parent-linkage and row order instead).
- **Parser** round-trip + rejection tests (`name(` accepted, `( SELECT` still rejected).
- **Unit** tests for the generators (row tuples for representative docs), mirroring `SQLJSONTests`.

## 9. Risks & open questions

- **Row-model generalization** is the main risk: today every non-FTS `RowSlot` decodes a byte-span; a TVF needs a "values, no span" slot for *N* synthetic columns. FTS shows the seam exists, but generalizing it cleanly (vs. special-casing) is the core design work and should land beside, not inside, the existing slot path.
- **Heavy overlap with the in-flight kernel strict-memory-safety refactor** (executor, row model, codecs). Recommend landing **after** that refactor settles to avoid churn; phases 1–2 (AST/parser/binder) are low-overlap and could start earlier if desired.
- **`.auto`/strategy matrix:** TVF sources must be added to `SQLStrategyMatrixTests` so every evaluator/join strategy agrees ≡ SQLite (ROADMAP §1 discipline).
- **Open:** whether to materialize eagerly (this RFC's choice — simplest, doc already in memory) or stream over the tape (saves memory on huge arrays; revisit only if a workload needs it).

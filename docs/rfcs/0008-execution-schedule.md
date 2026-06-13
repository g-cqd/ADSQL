# RFC 0008 — Execution Schedule: the two-act program (FTS → DSL)

Status: accepted (scheduling design-of-record). Sequences the two large designs now on
the books — **RFC 0007 (Full-Text Search & Ranking, M5)** and **RFC 0006 (Swift
Metaprogramming & DSL, M7)** — into two ordered acts, fixes the gates between phases, and
defines how progress is persisted. This RFC owns *when* and *in what order*; the *what/how*
lives in RFC 0006/0007. Companion to `ROADMAP.md` (the milestone source of truth) and the
task list. Unlike the design RFCs, this one is operational: its **status table is live** and
bumped every slice.

## Why this RFC

Two milestone-sized bodies of work are designed and ready. Executing them in the wrong order
costs rework, and an undocumented schedule loses the *reasons* for the ordering the moment
context rolls over. The deciding fact is structural:

> **The public AST (`SQL/AST.swift`) is the shared substrate.** RFC 0007 **extends** it
> (a `CREATE VIRTUAL TABLE` statement node, `SQLBinaryOp.match`, the `bm25()`/`rank` value,
> a `CREATE TRIGGER` node). RFC 0006 **lowers into** it (a result-builder + operators →
> `SQLStatementAST`, executed through a new `prepare(ast:)` seam).

A DSL built first is reworked every time FTS extends the AST; a DSL built *after* FTS is
**born complete** — it covers MATCH/bm25/triggers from its first commit. Independently, FTS
is the **apple-docs migration blocker** (apple-docs search is 100% FTS5; the DSL blocks
nothing). Both arrows point the same way: **FTS first, DSL second.**

## Decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | **Act order: FTS (RFC 0007 / M5) → DSL (RFC 0006 / M7).** | AST is the shared substrate (FTS extends it, the DSL lowers to it); FTS is the migration blocker; the DSL blocks nothing. |
| **D2** | **Build the DSL in full, incl. the macro tier → adopt `swift-syntax`** (ADSQL's first large external dependency), **scoped** to a new `.macro` plugin target. `ADSQLKernel` stays **zero-dep**; the macro plugin is the *sole* `swift-syntax` consumer. | The type-safety/injection-safety payoff (RFC 0006 P1/P2) is wanted in full. The house "zero third-party deps" rule is **amended, not abandoned**: it holds absolutely for the kernel; the dependency is quarantined in a compile-time-only plugin. |
| **D3** | **Persist progress in three places:** this RFC (schedule + live status table), `ROADMAP.md` (milestone table + deferred-SQL registry), and the task list. **Commit-per-slice**; **every perf claim behind an `ADSQLBench` number** (the RFC 0002 discipline). | Survives context loss; keeps the *why* next to the *what*; matches the established review/RFC workflow. |

D2 amends the stance recorded in RFC 0003/0005 (zero-dep, swift-atomics-only). The amendment
is deliberate and bounded — see *Dependency scoping* below.

## Act I — RFC 0007 · FTS + bm25/bm25f (M5)

The apple-docs migration blocker. Per-FTS-table B+trees (term dictionary / block-compressed
postings + block-max impacts / doc-field stats), bm25f ranking, block-max WAND top-k. Each
phase is its own slice behind tests + a moving `ADSQLBench` number. Full design: RFC 0007.

| Phase | Scope | Primary surface |
|---|---|---|
| **F0** | `CREATE VIRTUAL TABLE … USING fts5(…)` parse + statement AST node; catalog **FTS record** (dictionary/postings/stats roots + config) + DROP + schema cache; storage key layout. *No query yet.* | `SQL/AST.swift`, `SQL/Parser.swift:412`, `Relation/{Catalog,Definitions}.swift`, `SQL/{Statement,Writer}.swift` |
| **F1** | Tokenizers `unicode61` / `porter` / `trigram` + `Tokenizer` protocol + unit tests. | `Sources/ADSQLKernel/FTS/Tokenizer*.swift` |
| **F2** | FTS write API; tokenize → block postings (+ block-max) + doc/field stats; content modes (self/external/contentless); segment flush + merge. | `FTS/{Postings,FTSIndex}.swift`, `Relation/DML.swift` |
| **F3** | `MATCH` op (`Parser.swift:694`, equality precedence; `SQLBinaryOp.match`) + query grammar; AND/OR/NOT/phrase/prefix → rowids; `AccessPlan.fts` + `RowSource.fts`. **Gate: membership differential-vs-CSQLite FTS5.** | `FTS/MatchQuery.swift`, `Planner.swift`, `Executor.swift` |
| **F4** | bm25 + bm25f per-column weights; block-max WAND/MaxScore top-k; `bm25()`/`rank` (`Parser.swift:954`) context-aware value; `ORDER BY rank LIMIT k` true top-k. | `FTS/BM25.swift`, `Functions.swift`, `Executor.swift` |
| **F5** | General `CREATE TRIGGER` (`Parser.swift:413`; NEW/OLD, AFTER I/U/D, body INSERT/DELETE) fired in DML. **Completes the AST extension → unblocks Act II.** | `FTS/Trigger.swift`, AST/Parser/Catalog/DML |
| **F6** | The 4 apple-docs tables/modes verbatim *in ADSQL*; `highlight`/`snippet` if needed; `ADSQLBench fts` + SQLite-FTS5 parity harness; perf-tune to **beat FTS5**. | `Sources/ADSQLBench/FTSScenario.swift` |

The apple-docs **repo** cutover (swapping `bun:sqlite`) is a downstream consumer task in the
*other* repo and is out of scope here — ADSQL work must not touch the apple-docs repo. F6
delivers the ADSQL-side enablement + parity evidence only.

## Act II — RFC 0006 · Query DSL & metaprogramming (M7)

Built on the **FTS-complete AST** (post-F5), so the DSL covers MATCH/bm25/`CREATE TRIGGER`
from day one. Full design: RFC 0006.

| Phase | Scope | Dependency |
|---|---|---|
| **P0** | `prepare(ast:)` seam (`Statement.swift:80-156,316`); result-builder DSL (`SQL{}`/`Select`/`From`/`Join`/`Where`/`GroupBy`/`Having`/`OrderBy`/`Limit` + DDL/DML); operators on a **non-`Equatable`** `SQLExpression` wrapper → injection-safe `.literal(Value)`. | **None** (`Sources/ADSQL/Query/*`) |
| **P1** | `.macro` target `ADSQLMacros` + the `swift-syntax` dep (isolated commit); `#SQL`; `@Table` (typed columns + predicates); `@dynamicMemberLookup` on **eager** `SQLRow`/`Row` (**not** throwing `RowView`, Review 0001 F1). | **swift-syntax** (`Sources/ADSQLMacros/*`, `Tests/ADSQLMacrosTests`) |
| **P2** | `@FixedLayout` for `Meta`/`PageHeader` (byte-identity test **before** swapping); `SQLExpr.mapChildren/children` walk refactor (**not** the hot `evaluate` switch); test-fixture DSL; callable `Query<Output>`. | swift-syntax (rides P1) |

## Gates

- **Per slice:** `swift build` (0 warnings, 0 strict-MS over-marks) · `swift test` · `swift
  test --sanitize=thread` green · commit-per-slice referencing the phase · bump this RFC's
  status table + `ROADMAP.md`.
- **F3 correctness gate:** boolean MATCH membership differential-vs-CSQLite FTS5 must pass
  before F4 ranking work begins.
- **Act boundary (F5 → P0):** Act II starts only once the AST is fully extended (F5 lands
  `CREATE TRIGGER`). F6 (perf/parity/tables) does **not** reshape the AST, so it *may* overlap
  P0; default is sequential.
- **swift-syntax gate (P0 → P1):** the dependency is added in its **own commit** with a
  recorded clean-build-time delta; `ADSQLKernel` and `ADSQL` core stay dependency-free; only
  the `ADSQLMacros` plugin links swift-syntax.

## Dependency scoping (D2 in detail)

`swift-syntax` enters as a **compile-time-only** dependency of a single SwiftPM `.macro`
target (`ADSQLMacros`, a `CompilerPlugin`). It is **not** linked into `ADSQLKernel`,
`ADSQL` (runtime), `ADSQLBench`, or any shipping artifact — macros expand at build time and
emit ordinary Swift. The zero-dep invariant therefore holds for everything that runs; the
amendment is confined to the build graph of the macro plugin. If the macro tier is ever cut,
deleting one target restores strict zero-dep. This is the bounded, reversible shape that makes
D2 acceptable against RFC 0003/0005.

## Tracking convention (how progress is persisted)

1. **This RFC** is the design-of-record: it holds D1–D3 and the **live status table** below
   (phase → state → commit), updated in the same slice that advances the phase.
2. **`ROADMAP.md`** milestone table reflects M5 (Act I) and M7 (Act II); the deferred-SQL
   registry moves `CREATE VIRTUAL TABLE`/`MATCH`/`bm25()` from "M5 deferred" → "M5 in
   progress"; deps/non-goals record the scoped swift-syntax adoption.
3. **Task list** mirrors the phases with `blockedBy` edges (F1←F0…F6←F5; P0←F5; P1←P0; P2←P1)
   and phase-tagged commit messages (`feat(fts): F0 …`, `feat(dsl): P0 …`).

M6 (hardening + importer) is **not** part of this two-act program; it remains queued in
`ROADMAP.md`. The FTS format-version bump + crash-injection coverage (RFC 0007, On-disk
format) feed M6 but are scheduled within F0/F6, not here.

## Status (live — bump every slice)

| Phase | Milestone | State | Commit |
|---|---|---|---|
| D0 · schedule artifacts | — | ✅ done | `docs(rfc): 0008` (5c5ddb4) |
| F0 · foundations | M5 | ✅ done | `feat(fts): F0` |
| F1 · tokenizers | M5 | ✅ done | `feat(fts): F1` |
| F2 · index build + maintenance | M5 | ✅ done | `feat(fts): F2a/F2b/F2c` — postings codec, self-contained build/maintenance, content modes + 'delete' idiom (segments deferred to F6) |
| F3 · boolean MATCH | M5 | 🚧 in progress | F3a grammar `feat(fts): F3a` + F3b eval `feat(fts): F3b`; F3c SQL/MATCH surface + differential gate next |
| F4 · ranking (bm25/bm25f) | M5 | ⏳ planned | — |
| F5 · triggers | M5 | ⏳ planned | — |
| F6 · apple-docs tables + bench | M5 | ⏳ planned | — |
| P0 · DSL dep-free core | M7 | 🔒 blocked (F5) | — |
| P1 · macro tier (swift-syntax) | M7 | 🔒 blocked (P0) | — |
| P2 · internal codegen | M7 | 🔒 blocked (P1) | — |

Legend: 🚧 in progress · ⏭ next · ⏳ planned · 🔒 blocked · ✅ done.

## References

Design RFCs: **0007** (FTS & ranking — the Act I design), **0006** (metaprogramming & DSL —
the Act II design). Discipline: **0002/Review 0002** (every perf claim behind a bench number),
**Review 0001** (the `RowView` throwing/`~Escapable` constraint — F1, gates `@dynamicMemberLookup`).
Dependency stance amended: **0003/0005** (zero-dep; swift-atomics-only) → D2 scopes the first
large dep to the macro plugin. Source of truth for milestone status: `ROADMAP.md`.

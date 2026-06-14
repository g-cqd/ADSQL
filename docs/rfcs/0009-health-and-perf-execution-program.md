# RFC 0009 — Execution Schedule: Codebase Health + Performance-Maturity Program

Status: **accepted (operational schedule-of-record); live status table — bump every slice.**

Sequences the consolidated health check **and** the "beat SQLite everywhere" performance-maturity program
recorded in `docs/reviews/0003-codebase-health-and-perf.md`. This RFC owns ***when* and *in what order***;
the ***what/how*** (findings, designs, scorecards, correctness landmines, risk register) lives in review
0003. Companion to `ROADMAP.md` (milestone source of truth) and the task list. Like RFC 0008, this is
**operational**: its status table (§Status) is live.

## Why this RFC

Review 0003 consolidates two reports into a single durable knowledge store and enumerates the remaining
work (S1/S2/C/S3/S4 quality + the JOIN/INSERT/evaluator perf program + a bench expansion). That work is
multi-week and must survive context loss, execute in a deliberate order, and be gated identically every
slice. An undocumented schedule loses the *reasons* for the ordering the moment context rolls over. This
RFC fixes the order, the gates, and the tracking convention.

This program is **orthogonal to RFC 0008's FTS→DSL act schedule**: RFC 0008 owns M5 (FTS, done through
F6) and M7 (DSL/macros, Act II). RFC 0009 owns the **cross-cutting health pass and the SQL
performance-maturity program** (RFC 0004's lineage), plus the FTS *bench* expansion. The two share the
seven-criteria discipline and the commit-per-slice rule.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| **E1** | **Documentation first, losslessly, before any code change.** Persist all knowledge in-repo: verbatim archive of both source reports (`docs/reviews/archive/`), the consolidated review (0003), this RFC (0009), `ROADMAP.md` links. | Owner mandate: "the repo should contain all the knowledge; no loss of information." Survives context loss (RFC 0008 D3 discipline). |
| **E2** | **Measure first.** Re-baseline the full `ADSQLBench` matrix (incl. FTS) at HEAD before optimizing; expand the bench (FTS shapes/bm25f + a multi-criteria strategy harness) as the **measurement substrate** before the perf algorithms. | "No marginal gains, track every optimization" requires a trustworthy before/after; the strategy harness is the gate that authorizes retiring code. |
| **E3** | **Strategy-beside for algorithm swaps; in-place only for proven pure wins.** Add each alternative (`merge`/`auto`/`hoisted`/`appendCursor`/`vdbe`) beside the verified reference; retire nothing until it wins on **all seven criteria**. *Pure-win* waste (byte-identical results, strictly fewer ops) may be fixed in place — but only with **proven no-regression, proven safety, added tests, and same-or-strictly-better performance** (owner waste policy). | Preserves the perf report's safety discipline while honoring the new "clear all waste" directive. The seam (`ExecutionOptions`) and `planningTag` already exist. |
| **E4** | **Commit-per-slice; every perf claim behind an `ADSQLBench` number** (RFC 0002 discipline); bump this RFC's status table + `ROADMAP.md` in the same slice. | Reviewable, bisectable, durable. |
| **E5** | **API-shaping (S1 `public`→`package`, C strong-ID types) lands *after* the structural and perf churn settles** (Phase 7), to minimize rebase pain and semver thrash. | S1 is external-API-breaking; doing it last avoids re-touching demoted symbols repeatedly. |

## Phases

Designs for every phase are in **review 0003 §6**; this table is the schedule + the per-phase gate.

| Phase | Scope | Primary surface | Gate (beyond the standing gate) |
|---|---|---|---|
| **H0** | **Docs-first + re-baseline.** Archive originals; write 0003 + 0009; update ROADMAP; supersede `/Public/` originals. Then `swift build -c release` + full bench matrix back-to-back (`cold get scan concurrent upsert table sql fts`, `--join hash\|auto`, `--eval compiled`); `/usr/bin/sample` JOIN+INSERT; fold numbers into 0003 §4 + this RFC's baseline row. | `docs/reviews/{0003,archive/*}`, `docs/rfcs/0009`, `ROADMAP.md` | docs lossless (a cold reader recovers everything); baseline numbers recorded as the "before". |
| **H1** | **Measurement substrate.** Expand FTS bench (3 missing apple-docs shapes, bm25f weighted arm, snippet/highlight, update/delete churn, concurrent-FTS readers, raise `rowCap`, `--fts-full`); add `StrategyBench.swift` + `--strategy-matrix` (seven criteria per scenario×strategy). | `ADSQLBench/{FTSScenario,Scenarios,main}.swift`; new `ADSQLBench/StrategyBench.swift` | new arms run on both engines; numbers reproducible back-to-back. |
| **H2** | **Structure (S2) + safe-type micro-fixes.** Split the six god-files (pure code motion, one commit/file) under ~600 lines; guard-throw `Postings` force-unwraps; drop redundant `unsafe` in `FTSIndex`; guard `Trigram:60`. | `SQL/{Executor,Parser,Plan,Writer}.swift`, `Relation/{Relation,DML}.swift` → new `SQL/{JoinExecutor,AggregateExecutor,ResultPipeline,Binder,Parser+DDL,Parser+Expr}.swift`; `FTS/{Postings,FTSIndex,Trigram}.swift` | diffs are move-only / no behavior change; no `SQL/` or `Relation/` file > ~600 lines. |
| **H3** | **INSERT `hoisted` + codec waste (W1/W3/W4/W7).** Per-statement `InsertPlan` (hoist owned-index filter+sort, reuse conflict cursors, mutate state in place); scratch `rowKey`; opportunistic zero-copy reads. | `Relation/DML.swift`, `RelationState`, `TxnContext.swift`, `RecordCodec.swift` | seven-criteria differential `standard ≡ hoisted ≡ SQLite` (+ byte-identical dump) + crash-injection; INSERT same-or-better. |
| **H4** | **JOIN: merge + cost model + hash semi-join (W6).** `MergeJoin.swift` (`Join.merge`); cost model `Join.auto` (`Planner.planJoin` + `BoundJoin.driver`, `TreeHandle.count`); hash semi-join in `runInnerHashJoin`. | `SQL/{Executor,Planner,Plan,ExecutionOptions}.swift`; new `SQL/MergeJoin.swift` | `nestedLoop ≡ hash ≡ merge ≡ auto ≡ SQLite` matrix; merge **beats** SQLite on the self-join before `auto` defaults to it. |
| **H5** | **INSERT `appendCursor` (W2; crash-critical).** Warm rightmost-leaf cache on `TxnContext`; ascending-rowid in-place append; fall through to `BTree.put` on split/non-ascending/stale; invalidate on rollback/DDL. | new `Relation/AppendCursor.swift`; `TxnContext.swift`, `BTree.swift` | **hard** crash-injection (`barrierProfileSweepEveryCutGroup`, `randomizedCrashStorm`), esp. mid-split; full matrix; drop if not spotless. |
| **H6** | **Evaluator + the unifying row path (W5; closes JOIN/SEARCH/MATCH).** Widen `CompiledEval` (join ON, residual, aggregate finalize, like/inList/function); attack per-row `[Value]`/ARC/exclusivity on `Accumulator.consume`/`project` via local-`var` accumulation; build `SQL/VDBE/` register machine incrementally. | `SQL/{CompiledEval,Eval,Executor}.swift`; new `SQL/VDBE/{Opcode,Program,Machine}.swift` | full `SQLStrategyMatrixTests` agrees across every evaluator and SQLite; byte-identical state. |
| **H7** | **Public surface (S1) + strong-ID types (C).** Demote storage internals `public`→`package` (keep the intended API public; `ADSQLTestSupport` needs `package`); scoped `PageNumber`/`Generation` wrappers at the highest-signal boundaries only. | `Sources/ADSQL/ADSQL.swift`, kernel `public` decls; `MetaPage.swift`, `FreeList.swift`, `Pager.swift` | all four products + both test targets build; API == intended contract; bench-neutral (devirtualizes to bare ints). |
| **H8** | **Selection & retirement.** Flip a default per dimension only after it wins all seven criteria (`join=.auto`; evaluator→compiled/vdbe; insert→hoisted/appendCursor); keep the superseded path selectable one release. | `SQL/ExecutionOptions.swift` defaults; `ROADMAP.md`, RFC 0008/0009, review 0003 | the seven-criteria matrix is the sole authority to retire a path. |

## Gates

- **Standing gate (every slice):** `swift build` clean (0 warnings, 0 strict-MS over-marks) · `swift test`
  green (incl. CSQLite differential + strategy matrix) · `swift test --sanitize=thread` green on changed
  row/scan/write paths · crash-injection green on write paths · `ADSQLBench` perf-neutral-or-better on the
  default config · one concern per commit · **read the log's own summary line, not the wrapper exit code.**
- **New-strategy gate (H3–H6):** seven-criteria differential (`reference ≡ alternative ≡ SQLite`,
  byte-identical DB dump) + `Integrity.deepCheck` before any default flip.
- **H5 hard gate:** crash-injection must be spotless mid-split or the strategy is dropped.
- **Default-flip gate (H8):** all seven criteria won, measured by the H1 strategy harness.

## Tracking convention

1. **This RFC** holds E1–E5 and the **live status table** below (phase → state → commit), bumped in the
   slice that advances the phase.
2. **`docs/reviews/0003`** holds the findings/designs/scorecards; its §4 baseline + scorecards are updated
   as numbers land.
3. **`ROADMAP.md`** links 0003 + 0009 and reflects the perf-maturity + health pass as active.
4. **Task list** mirrors the phases with `blockedBy` edges (H1←H0; H2←H0; H3←H1; H4←H1; H5←H4; H6←H1;
   H7←H2,H6; H8←H3,H4,H5,H6) and phase-tagged commit messages (`docs(review): 0003 …`, `perf(join): H4 …`,
   `refactor(sql): H2 …`).

## Status (live — bump every slice)

| Phase | State | Commit / note |
|---|---|---|
| H0 · docs-first | ✅ done | archive ✅; review 0003 ✅; RFC 0009 ✅; ROADMAP + `/Public/` supersede ✅ (`e63b7a4`); SQL re-baseline ✅ (`e147bde` — release build clean 0-warn; JOIN 0.26× / INSERT 0.74× confirmed, DISTINCT 2.0× / SEARCH≈parity; FTS arm deferred to RFC 0008 under active F6 iteration) |
| H1 · measurement substrate | 🚧 in progress | bm25f weighted ranked arm ✅ (`0ded91e`); `StrategyBench` `strategy` scenario ✅ (join×eval matrix + SQLite baseline — smoke reproduces finding #1: hash ~2.3× slower than nested-loop on the symmetric self-join). Follow-on: trigram/contentless/prefix FTS shapes + snippet/churn/concurrent arms |
| H2 · structure + safe-type fixes | 🚧 in progress | `enum Binder` extracted `Plan.swift`→`Binder.swift` ✅ (975→211+764, pure motion, 339 tests green). **Safe-type micro-fixes (finding #8) closed — NO ACTION, all three re-verified already-correct at HEAD:** `Postings.first!/.last!` are provably non-empty (`while index<count` loop invariant; internal encoder data, not an untrusted boundary), `FTSIndex` `unsafe` is *required* (F6k/F6n zero-copy raw-buffer read), `Trigram:60` is range-guarded on the same line. Remaining: Executor/Parser/Writer/Relation/DML structural splits. |
| H3 · INSERT hoisted + codec waste | 🔒 blocked (H1) | `Insert.hoisted` + W1/W3/W4/W7 |
| H4 · JOIN merge + cost model + semi-join | 🔒 blocked (H1) | `Join.merge`/`.auto` + hash semi-join |
| H5 · INSERT appendCursor | 🔒 blocked (H4) | crash-critical warm-cache append |
| H6 · evaluator + row path | 🔒 blocked (H1) | wider `CompiledEval` + VDBE + W5 |
| H7 · surface (S1) + strong IDs (C) | 🔒 blocked (H2,H6) | `public`→`package`; scoped typedefs |
| H8 · selection & retirement | 🔒 blocked (H3,H4,H5,H6) | flip defaults on a seven-criteria win |

Legend: 🚧 in progress · ⏭ next · ⏳ planned · 🔒 blocked · ✅ done.

## References

- **`docs/reviews/0003-codebase-health-and-perf.md`** — the consolidated findings, designs, scorecards,
  correctness landmines (§8), risk register (§9), measurement methodology (§10). The *what/how*.
- **`docs/reviews/archive/2026-06-14-*.md`** — the two source reports, verbatim.
- **RFC 0002 / Review 0002** — every perf claim behind a bench number (discipline).
- **RFC 0004** — the original performance-optimization program (lineage of the perf-maturity work).
- **RFC 0005** — Apple-native API adoption (`os.Logger`/signposts, `import System`, Accelerate) — may ride
  H1 if it pays for itself, else deferred.
- **RFC 0008** — the FTS→DSL act schedule (M5/M7); shares the seven-criteria + commit-per-slice discipline.
- **Review 0001** — the strict-memory-safety / `~Escapable` constraints honored throughout.
- Source of truth for milestone status: **`ROADMAP.md`**.

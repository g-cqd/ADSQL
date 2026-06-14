<!--
  ARCHIVED VERBATIM (Deliverable 0-A) — durable in-repo knowledge preservation.
  Source: /Users/gc/Public/ADSQL/reports/2026-06-14-health-check-remaining-work.md
  Consolidated & reconciled to HEAD in ../0003-codebase-health-and-perf.md
  Execution program in ../../rfcs/0009-health-and-perf-execution-program.md
  The content below is byte-for-byte unmodified; do not edit — edit 0003 instead.
-->

# ADSQL — Codebase Health Check: Findings, Goal, Targets & Remaining Work

**Date:** 2026-06-14
**Repo:** `/Users/gc/Developer/ongoing/swift/ADSQL`
**Baseline commit:** `1c3bccf` (working tree clean) — line numbers below are as of this commit and may drift as the tree evolves; prefer the named symbols/`// MARK:` anchors.
**Toolchain:** Swift 6.2 language mode / 6.4 toolchain · `.strictMemorySafety()` (SE-0458) + experimental `Lifetimes` (SE-0446/0456) on `ADSQLKernel` · `platforms: [.macOS(.v26)]` · **zero external dependencies**.
**Build/test status:** `swift build` clean (0 warnings); `swift test` green — **330 tests in 76 suites** (~23.5 s).

> **Scope of this document.** ADSQL is a from-scratch, pure-Swift embedded SQL database engine. This report is the durable record of a whole-codebase quality & health check: the goal, the architecture as it actually is, what was found, what was fixed (and committed), and a detailed, prioritized plan for what remains. It is written to be picked up cold by a future engineer or agent.

---

## 0. Executive verdict

ADSQL is an **exceptionally disciplined codebase** — among the cleanest storage engines reviewable. Typed `throws(DBError)` is universal below the public façade and the claim holds *exactly*; the prior strict-memory-safety audit (Review 0001) is genuinely resolved (verified, no regressions); the MVCC concurrency, atomics orderings, crash recovery, free-list reclamation horizon, and the disk-**value** decoders are correct and bounds-checked. The gaps are narrow and specific, in three buckets:

1. **Reliability/integrity** — one real read-path gap (page-structure fields were trusted on the hot path). **Fixed** this engagement (R1/R2).
2. **Consistency / Apple-native safe types** — a thread-safety bug (`strerror`) and a BE-decode inconsistency, both **fixed** (R3/C3); plus a remaining strong-typedef opportunity (C, recommended scoped).
3. **Structure / separation of concerns** — god-files and an over-broad public surface (S2/S1, **remaining**).

Nothing is systemically wrong; this is polish on a strong foundation.

---

## 1. Goal (north star) & quality dimensions

Make the engine **coherent, consistent, reliable, and integrity-preserving by construction**, with boundaries enforced by the type system and access control rather than convention.

| Dimension | Concrete objective |
|---|---|
| **Coherency & consistency** | One idiom per concern; eliminate "two ways to do the same thing" (e.g. BE decode, error construction). |
| **Separation of concerns** | module → folder → file → scope boundaries; cohesive single-purpose files; access control used as a boundary tool. |
| **Reliability & integrity** | Corruption, torn writes, and **untrusted on-disk input** fail **closed** with typed `DBError`s — never traps or silent wrong answers. A database file is an attacker-controllable input surface. |
| **Conformance to norms** | Modern Swift idioms; Apple-native safe types where they add real safety; **green CI on the pinned toolchain**. |
| **Apple-native safe types** | typed throws ✅ · `Span`/`RawSpan`/`~Escapable` page views ✅ · strong ID typedefs ⏳ · `Duration`/`ContinuousClock` on measurement surfaces ⏳. |

**Non-negotiable gate for every change:** `swift test` **and** `swift test --sanitize=thread` stay green, and the change is **perf-neutral on `ADSQLBench`** — being faster than system SQLite is the core value proposition (see `README.md` benchmark table: 13× faster cold-open p50, 4× point-get p50, 2.9× bulk load, etc.).

---

## 2. Architecture & design model (as built)

A single Swift module, `ADSQLKernel`, organized by folder; a thin public façade `ADSQL` re-exports it; `ADSQLTool` (CLI) and `ADSQLBench` (benchmarks vs system SQLite) sit on top.

```
ADSQLBench / ADSQLTool        (executables)
        │
      ADSQL                   (façade: @_exported import ADSQLKernel + ADSQLInfo)
        │
   ADSQLKernel  ── ADCAtomics (C shim: cross-process u64 acquire/release/CAS)
     ├─ (root)   VFS, mmap, COW B+tree, pager, MVCC, free-list, commit, recovery, integrity
     ├─ Relation/ catalog, DML, definitions, key/record codecs, rows, values, FKs, civil-time
     ├─ SQL/      lexer, parser, AST, planner/binder, plan, executor, eval, functions, JSON, pragma
     └─ FTS/      tokenizers (unicode61/porter/trigram), postings, scorer (bm25), match, triggers
```

**Design pillars (do not undo):**
- **Copy-on-write B+tree over `mmap`.** Committed pages are immutable; a write shadows pages root→leaf into freshly allocated page numbers (`TxnContext.shadow`), publishing a new meta only after data + barrier.
- **Single-writer / wait-free reader MVCC.** Any number of readers run lock-free over an immutable snapshot (a `Meta` generation). One writer at a time (serial `WriterThread` + `fcntl(F_WRLCK)`). Readers register a generation; the writer's reclamation horizon never passes a live reader.
- **Crash-safe by construction.** No WAL/undo log: recovery = pick the newest checksum-valid meta page. Reuse of freed pages lags one generation, so recovery to N−1 is always sound.
- **Zero dependencies; mature syscall layer.** `clonefile(2)` snapshots, `F_PREALLOCATE`/`F_NOCACHE`, `F_BARRIERFSYNC`/`F_FULLFSYNC` durability profiles, `mmap`+`madvise(MADV_RANDOM)`.
- **Strict memory safety.** Every unsafe construct is marked `unsafe` or encapsulated by a `@safe` type; the two highest-exposure borrowed page views are compiler-enforced `~Escapable` over `RawSpan`.

### On-disk format & integrity model (verified, current tree)

- **Page = 16 KiB.** Pages 0/1 are the two meta pages (ping-pong by `generation % 2`, `Meta.pageNo` at `MetaPage.swift:48`); data pages start at `Format.firstDataPage = 2`.
- **Per-page checksum:** XXH64 over page bytes `8..<16384` **seeded with the page number** — `PageHeader.stampChecksum` (`Page.swift:100`) / `verifyChecksum` (`Page.swift:105`). Stamped once per dirty page at commit.
- **Commit protocol** (`Committer.commit`, `Committer.swift:18`; doc at `:8–14`): write all data pages → barrier → flip the meta. `newMeta.generation = old + 1` (`:28`). A torn in-flight meta falls back one generation (`:12`, `:62`).
- **Recovery / meta selection** (`Meta.recover`, `MetaPage.swift:145`): highest-`generation` **checksum-valid** meta wins (`:158`); both-invalid is fatal (`DBError.bothMetasInvalid`).
- **Reclamation horizon (closes the page-recycling UAF, CWE-416):** a reader publishes its min generation via `ReaderTable.publish` → `adc_store_release_u64` (`ReaderTable.swift:126–128`); the writer reads slots via `adc_load_acquire_u64` (`minimumGeneration`, `:133–137`), takes `min(localMin, foreignMin)` (`WriterLoop.swift:74`), and `reclaimLimit = min(minReader, generation−1)` (`Meta.reclaimLimit`, `MetaPage.swift:56–57`). A harvested page is provably unreferenced by any tree a live reader can see.
- **Single-writer & lifecycle:** writer lock `fcntl(F_WRLCK)` held for the handle's life (`ReaderTable.swift:69`); double-close guarded by `didShutdown.exchange(true, ordering: .acquiringAndReleasing)` (`WriterThread.swift:155`).
- **Cross-process atomics:** the `ADCAtomics` C shim exposes `adc_load_acquire_u64`/`adc_store_release_u64` (`Sources/ADCAtomics/include/adcatomics.h:12,17`) over `MAP_SHARED` lock-file slots — the one thing stdlib `Synchronization.Atomic` cannot do (it owns its storage; can't alias a chosen mmap offset across processes).
- **Untrusted-input decoding:** the record/key/overflow/varint decoders validate every on-disk length against the buffer **before** slicing (e.g. `RecordCodec.swift:158–166, 210–224`; `KeyCodec.decodeField`/`readBE`/`readEscaped`; `Varint.read` overflow guard). This is the well-guarded part of the integrity surface.

---

## 3. What's already excellent (do **not** re-propose)

So future work doesn't waste effort relitigating settled, verified-good decisions:

- **Typed throws are exact.** Zero untyped `throws` below the façade; the kernel is `throws(DBError)` end to end. Untyped `throws` exists only in `ADSQLBench`.
- **Review 0001 fully resolved (re-verified):** `RowView` (`Rows.swift:40`) and `BTree.ValueRef` are genuine `~Copyable, ~Escapable` over `RawSpan`, lifetime-bound to the snapshot resolver via `_overrideLifetime`; `MMap.base` is `private`; `PageBuf.raw` is `internal`; the `_unsafeBytes:` SPI is confined to one `ReadTxn.withRawSpan` bridge; **zero** `nonisolated(unsafe)` anywhere in `Sources/` or `Tests/`.
- **Concurrency-race correctness:** atomic orderings correct, single-writer enforced, double-close idempotent, recovery sound — no findings.
- **Disk-value decoders** rigorously bounds-check before slicing (§2).
- **No material duplication** (varint centralized in `ByteCodec.Varint`); **no dead code** (`TrigramTokenizer` is live via `Tokenizer.swift`); debt markers are false positives (SQL keyword strings, not TODOs).
- **`Sendable` discipline is clean:** every `@unchecked Sendable` (`Pager`, `MMap`, `ReaderTable`, `FileChannel`, `WriterThread` boxes) is documented and genuinely needs the escape hatch; none could be plain `Sendable`. No actors; no `nonisolated` misuse.
- **Float `==` sites are intentional** (exact-zero normalization, round-trip/representability checks) — not accidental float equality.

---

## 4. Methodology & how findings were verified

- Three non-overlapping deep-dive audits run in parallel: **structure/separation-of-concerns**, **Swift idioms/Apple-native safe types**, **memory-safety/integrity** — each evidence-based with file:line.
- Every load-bearing claim was **independently re-verified** against source before being treated as fact (e.g. the page-bounds gap at `NodeBuilder.leafCell`, the zero external usage of storage primitives, the `verifyChecksums:` default).
- **Lesson worth recording:** background `swift build`/`swift test` "exit code 0/1" notifications reflect the *last command in the shell pipeline*, not the compiler/test outcome. Three times a trailing `tail`/`echo`/`grep -c` masked the real result (a `grep -c` with zero matches exits 1). **Always read the build/test log's own summary line** (`Test run with N tests ... passed`, `error:`), never trust the wrapper exit code.

---

## 5. Done & committed (this engagement)

| ID | Change | Where | Commit |
|---|---|---|---|
| **C3** | `ByteCodec.loadBE64` (single byte-swapped load); replaced two manual BE shift-loops in `KeyCodec.readBE` / `rowid(fromSuffixOf:)` | `ByteCodec.swift`, `KeyCodec.swift` | `8ddcc9a` |
| **R2** | Always-on snapshot **`pageCount` guard** in `CommittedResolver.resolvePage` + `TxnContext.resolvePage` — a corrupt in-page pointer into mapped-but-uncommitted (zeroed) space now throws `DBError.corruptPage` instead of silently reading it | `TxnContext.swift`, `Integrity.swift`, `Database.swift` | `6ccde9a` |
| **R1** | Opt-in **`DatabaseOptions.verifyChecksumsOnRead`** (default off) — checksum-verifies committed pages as they fault in; catches the full corruption class for untrusted files without regressing the hot path | `Database.swift`, `TxnContext.swift` | `6ccde9a` |
| **R1/R2 tests** | `IntegrityGuardTests` — out-of-range page rejected; flipped free-space byte is silent without verify, caught with it | `Tests/.../IntegrityGuardTests.swift` | `6ccde9a` |
| **R3** | Thread-safe `strerror_r` in `DBError.description` (was non-reentrant `strerror`, shared static buffer) | `Errors.swift` | `18e5cb7` |
| **S3 (JSON)** | 8 direct unit tests for the no-Foundation JSON parser: surrogate pairs, lone-surrogate→U+FFFD, path extraction, malformed handling, render round-trip | `Tests/.../SQLJSONTests.swift` | `509fa33` |
| **CI** | Fixed invalid `--skip-tag soak` flag (CI was red on the pinned toolchain; no soak-tagged tests existed) → `swift test`; subsequently evolved by the owner to genuinely run soak-tagged tests | `.github/workflows/ci.yml` | folded / `86d9bde` |

**Related robustness/consistency work by the owner, same themes:** `7847e7c` (catchable `DBError` for over-long table/FTS names instead of trapping), `991020c` (optional-chaining idioms over nil-check-then-force-unwrap).

**Finding corrected during the work — C2 (dropped):** the proposed `UInt16(exactly: v)!` adds nothing. Swift's `UInt16(value)` integer-narrowing initializer **already traps** on out-of-range (the *wrapping* form is `UInt16(truncatingIfNeeded:)`, which the code does not use). The slotted-page writes (`Page.swift` setters, `NodeBuilder` encoders) already fail closed.

---

## 6. Remaining work (prioritized, with goal · target · risk)

### S2 — Split the god-files · *value: HIGH · risk: LOW (pure code-motion) · effort: M–L · prereq: none*

**Goal:** restore cohesion; one concern per file; keep the SQL layer navigable. **Why now:** `Executor.swift` is **1565 lines** and growing with evaluator/FTS work.

**`SQL/Executor.swift` (1565 lines)** — `enum SelectExecutor` holds ≥6 concerns (current `// MARK:` map):

| Concern | Lines (≈) | Move to |
|---|---|---|
| `RowSlot` (`@safe`) + `SelectExecutor` core | 28, 152–359 | stays in `Executor.swift` |
| Row sources, `RowSource`, `Accumulator` | 360–682 | `RowSourceExecutor.swift` (or keep) |
| **Joins** (nested-loop, null-extension) | 683–1048 | **`JoinExecutor.swift`** |
| **Aggregation** (GROUP BY/COUNT/SUM/HAVING) | 1049–1174 | **`AggregateExecutor.swift`** (pairs with `Aggregate.swift`/`Grouping.swift`) |
| Probe eval & type-boundary coercion (`BuiltBounds`, `Coerced`) | 1175–1284 | `ProbeEval.swift` (or with row sources) |
| **Compounds** (UNION/UNION ALL) | 1285–1334 | **`ResultPipeline.swift`** |
| Evaluation env / `RowContext` | 1335–1411 | `RowContext.swift` (or keep) |
| **DISTINCT / ORDER BY / LIMIT-OFFSET** | 1412–1565 | **`ResultPipeline.swift`** |

**`SQL/Plan.swift` (975)** — keep the bound-plan **data types** (`TableBinding` `:13`, `BoundOutput` `:79`, `BoundJoin` `:87`, `QueryBinding` `:109`, `BoundSelect` `:138`, `BoundQuery` `:186`, `BoundCompound` `:194`, `extension TableDefinition` `:65`); extract the ~760-line **`enum Binder` (`:212`)** → **`Binder.swift`** (it also does join-equality analysis, aggregate rewriting, access binding).

**`SQL/Parser.swift` (1148)** — one `SQLParser` with clean sub-grammars by `// MARK:`: token helpers (`:43`), statements/SELECT/DML (`:121–428`), **DDL (`:429–851`, ~420 lines: `create`, `createVirtualTable`, `createTrigger`, `createTableBody`, `columnType`, `defaultClause`, `referencesClause`, `drop`)** → **`Parser+DDL.swift`**; **expressions (`:852–1148`, precedence climbing)** → **`Parser+Expr.swift`**.

**Target / acceptance:** no `SQL/` file over ~600 lines; each new file one MARK-coherent concern; **diff is pure move (zero behavior change)**; `swift test` + TSan green; one independent, reviewable commit per extracted file.

### S1 — Tighten the public surface · *value: HIGH · risk: external-API-breaking · effort: M · prereq: confirm intended public contract*

**Goal:** stop the `@_exported import ADSQLKernel` façade from **publishing the entire storage engine** to library clients. The audit confirmed **zero** consumers above the kernel reference the storage primitives, yet they are all `public`.

**Key mechanism (refined):** use **`package`** access (SE-0386; already enabled — the build passes `-package-name adsql`), **not** `internal`, for storage primitives. Reason: **`Tests/ADSQLTestSupport` is a regular (non-`@testable`) library target** that legitimately consumes kernel internals (`MemKernel: PageSource`, `KernelOps` uses `CommittedResolver`/`Meta`/`Pager`/`BTree`). A regular target can only see `public` (or `package`) symbols. `package` hides them from **external** clients (removes the façade leak — the goal) while keeping **in-package** test-support access without `@testable`. Use `internal`/`private` only for symbols nothing outside the file/package needs.

**Demote `public` → `package`** (storage/impl internals; currently leaked):
`Pager`, `BTree`, `MMap`, `PageBuf`, `Committer`/`Recovery`, `Cursor`, `Node`(NodeBuilder), `PageHeader`(Page), `Overflow`/`OverflowPager`, `FreeList`, `FileChannel`/`StorageChannel`, `Meta`/`TreeHandle`(MetaPage), `PageType`, `Varint`(ByteCodec), `XXH64`, `TxnContext`/`CommittedResolver`/`PageSource`/`PageResolver`/`PageAllocator`, `RecordCodec`, `KeyCodec`, `RelationState`, `SchemaCache`, `Row`/`RowView`/`RowCursor`, `CivilTime`, and the FTS internals (`FTSPostings`/`FTSPosting`/`FTSDocStats`/`FTSGlobalStats`/`FTSToken`/`FTSTokenizer`/`FTSTokenizerFactory`/tokenizer structs) **unless** a public custom-tokenizer plug-in API is intended.

**Keep `public`** (the intended API contract): `Database`, `DatabaseOptions`, `ReadTxn`, `WriteTxn`, `Statement`, `SQLParameters`, `SQLRow`, `SQLColumnHeader`, `RunResult`, `SQLTransaction`, `DBError`, `Value`/`ColumnType`/`Collation`, all of `Relation/Definitions.swift` (schema types), `IntegrityReport` + `verifyIntegrity`, `ExecutionOptions`, `DurabilityProfile`, and `Format.formatVersion` (used by `ADSQLInfo`). **`SQL/AST.swift`** types and the lexer (`SQLParam`) are a judgment call — likely `package` (the parser is an implementation detail) unless AST construction/inspection is a supported API.

**Target / acceptance:** all four products + both test targets build; `swift test` green; the `ADSQL` library's public API is exactly the contract above. **Note:** semver-breaking for any hypothetical external code reaching into storage internals (the audit found none above the kernel — verify `ADSQLBench`/`ADSQLTool` still compile).

### C — Strong ID types · *value: MED · risk: MED · effort: M–L · prereq: agree scope — recommend SCOPED, not a full sweep*

**Goal:** make `pageNo` / `gen` / `slot` non-interchangeable so a mix-up is a compile error. Today they are bare `UInt64`/`UInt16` (`Meta.generation`/`pageCount`/`rootPage` `MetaPage.swift:7+`; `FreeList` `gen:UInt64, seq:UInt16`; `TxnContext` page args). `rowid` is already correctly `Int64` — good and distinct.

**Recommendation — do NOT mechanically sweep.** The engine is arithmetic-heavy (`pageNo * pageSize`, `highWater += 1`, BE key biasing) and *partial* typedef adoption is worse than none (conversion noise at every boundary). Introduce zero-cost wrappers only at the **highest-signal boundaries**:
```swift
struct PageNumber: RawRepresentable, Hashable, Comparable, Sendable { let rawValue: UInt64 }
struct Generation: RawRepresentable, Hashable, Comparable, Sendable { let rawValue: UInt64 }
```
applied to `Meta` fields, `PageAllocator`, and free-list `harvest`/`serialize`/`reclaimLimit` — where a `gen`-vs-`pageNo` swap is most plausible. **Target:** devirtualizes to a bare integer (no perf change on `ADSQLBench`); conversions confined to codec boundaries. **If it adds friction without catching anything real, don't ship it.**

### S3-remainder — Direct unit tests for under-tested units · *value: LOW · risk: none · effort: S · optional*

`SQL/Functions.swift` (`SQLFunctions`) and `SQL/Pragma.swift` have **no direct unit tests** (end-to-end covered; `CompiledEval` is locked by the strategy-matrix differential tests, so a direct test there is redundant). Add focused tests only for tricky branches — `SQLFunctions` numeric coercion / affinity / `realToText` formatting edges. Additive only.

### S4 (newly surfaced) — FTS cohesion smell · *value: LOW–MED · risk: LOW · effort: S–M*

`Relation/DML.swift`, `SQL/Writer.swift`, and `Relation/Relation.swift` each end with an embedded FTS maintenance block (index maintenance, FTS write path, `ftsCommand`). It is **not** duplication, but the FTS write path bleeding into generic DML is a cohesion smell. Consider moving the FTS write/trigger maintenance (e.g. `Writer.swift`'s FTS write section) into `FTS/` (a new `FTS/FTSWrite.swift` or beside `FTS/Trigger.swift`) so `Writer`/`DML` stay about generic DML.

---

## 7. Latent ledger (accepted-as-interim — tracked, **not** bugs)

Documented at the types today; resolve when the enabling refactor lands:

- **`RowSlot` / `LeafCell` / `LeafValue` are `@safe`-by-assertion** (temporal, CWE-416/562 class). They store a scope-bounded borrowed `UnsafeRawBufferPointer` and are consumed synchronously, but the compiler does not *enforce* non-escape. The enforced fix is the full `~Escapable` + `RawSpan` threading through the evaluator (`SQLEvalEnv.column` closure) and the node primitives (`NodeBuilder.leafCell` has no lifetime-bearing owner to bind to) — disproportionate today, so each carries a precise `// SAFETY:` note. (Review 0001 F1/F2.)
- **`PageBuf` `MutableRawSpan` / `withMutableBytes` migration deferred** (~60 in-module mutator sites). The naked `raw` pointer is already `internal`. (Review 0001 F4.)
- **Page-internal cell-field trust (residual of R1):** `Node.leafCell`/`branchKey`/`nodeKey` read `keyLen`/`valueLen`/`slotOffset` from a page and `rebasing:` slices; on a corrupt-but-in-`pageCount` page these still rely on the `UnsafeRawBufferPointer` subscript trapping in `-O` (fail-closed crash) unless `verifyChecksumsOnRead` is enabled. R2 closed the out-of-range-pointer hole; full structural validation on every read was deliberately **not** added (perf). Threat model: trusted-file-by-default, with `verifyChecksumsOnRead` for untrusted files.

---

## 8. Apple-native safe-type adoption — status

| Type / idiom | Status | Notes |
|---|---|---|
| Typed throws `throws(DBError)` | ✅ done | exact below the façade |
| `~Copyable` cursors/txns; `~Escapable` + `RawSpan` page views | ✅ done | `Cursor`, `ReadTxn`/`WriteTxn`, `RowView`, `ValueRef` |
| `Synchronization` `Mutex`/`Atomic` (explicit orderings) | ✅ done | in-process state, double-close guard |
| Thread-safe libc (`strerror_r`) | ✅ done (R3) | no other non-reentrant libc; `CivilTime` does its own math, not `localtime` |
| `loadBE64`/`loadLE*` unaligned loads | ✅ done (C3) | BE now consistent with LE |
| Strong ID typedefs (`PageNumber`/`Generation`) | ⏳ C (scoped) | bare `UInt64`/`UInt16` today |
| `Duration`/`ContinuousClock` | ⏳ bench only | kernel has **zero** time APIs (correct); `ADSQLBench` `Stats.nowNanos`/deadline math use raw `UInt64` |
| `InlineArray` (fixed-size) | ▫ marginal | `KeyCodec.rowKey`/`FreeList.entryKey` allocate tiny `[UInt8]`; `writeRowKey(into:)` already provides the allocation-free path |
| `os.Logger`/`OSSignposter`, `import System`, Accelerate, Compression | ▫ RFC 0005 | the project's own roadmap — out of scope here (§9) |

---

## 9. Out of scope here — the project's own roadmap (RFC 0005)

Already assessed/planned by the team; **do not duplicate**:
- `os.Logger` / `OSSignposter` instrumentation (P0 observability, the measurement substrate for the perf program) · `import System` for the basic fd/errno layer (P1, zero-dep) · Accelerate/SIMD + Compression (P2, benchmark-gated) · the **swift-atomics vs `ADCAtomics`** re-decision (capability is *not* the blocker — `UnsafeAtomic(at:)` can alias shared mmap; decide on dependency-hygiene grounds). See `docs/rfcs/0005-apple-native-api-adoption.md`, and `docs/reviews/0001` / `0002`.

---

## 10. Sequencing & acceptance gate

1. **S2** (now) — pure code-motion, highest navigability win; `Executor` is growing.
2. **S1** (after public-contract sign-off) — `public`→`package` via the `-package-name adsql` setting; external-API-breaking.
3. **C** (scoped, benchmark-gated).
4. **S3-remainder / S4** — anytime, additive.

**Gate for every commit:** `swift build` clean (0 warnings) · `swift test` green · `swift test --sanitize=thread` green · `ADSQLBench` perf-neutral · one concern per commit, reviewable. **Read the log summary, not the wrapper exit code** (§4).

---

## Appendix A — Commit map (this engagement)

| Commit | Contents |
|---|---|
| `8ddcc9a` | owner's evaluator-strategy work + C3 (`loadBE64`) |
| `6ccde9a` | R1/R2 read-path integrity guards + tests |
| `18e5cb7` | R3 thread-safe errno formatting |
| `509fa33` | S3 JSON parser unit tests |
| `7847e7c`, `991020c` | owner robustness/consistency (catchable over-long-name error; optional-chaining) |
| `86d9bde` | CI runs soak-tagged tests |
| `1c3bccf` | current `HEAD` (FTS F6 postings memtable) |

## Appendix B — Key anchors (as of `1c3bccf`)

- Integrity: `Page.swift:100/105` (checksum), `MetaPage.swift:145` (`recover`), `:56` (`reclaimLimit`), `Committer.swift:18` (`commit`), `ReaderTable.swift:126/133` (horizon), `adcatomics.h:12/17` (atomics).
- Read guards (R1/R2): `TxnContext.swift` (`resolvePage`, `CommittedResolver`), `Database.swift` (`DatabaseOptions.verifyChecksumsOnRead`, `read`).
- God-files: `SQL/Executor.swift` (1565), `SQL/Parser.swift` (1148), `SQL/Plan.swift` (975).
- Public-surface inventory: `grep -rnE "^public (final class|struct|enum|protocol) " Sources/ADSQLKernel`.
- Latent `@safe` views: `Executor.swift:28` (`RowSlot`), `NodeBuilder.swift` (`LeafCell`/`LeafValue`).

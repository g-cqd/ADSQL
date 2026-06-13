# Review 0001 — Strict-Memory-Safety Adoption: cheap-bypass audit

Status: review of **M4.7** (commits `caf0642` → `b61c455` → `27e74c0`, plus the
`Package.swift` flip that turns `.strictMemorySafety()` on for `ADSQLKernel`).
Audits the slice recorded in RFC 0003 → *"M4.7 implementation outcomes."*

Reviewer lens (SE-0458): is each escape valve — `unsafe` marker, `@safe` type,
`@unchecked Sendable`, `nonisolated(unsafe)` — a *justified necessity* or a
*cheap bypass* where the type system could have enforced safety instead of the
developer asserting it? Method: the memory-safety IRON LAW — every unsafe site
must state owner / lifetime / bounds; **an asserted invariant is not an enforced
one.**

## Verdict

Mechanically the slice is good: ~620 unsafe expressions surfaced, 1280 advisories
→ 0, TSan clean, 208 tests green, perf-neutral. One **systemic** issue remains:
`@safe` is used to certify **escapable, borrowed-pointer views** — `RowSlot`,
`RowView`, `BTree.ValueRef`, `NodeBuilder.LeafCell`/`LeafValue` — so on those
types `@safe` is a **hand-asserted temporal (lifetime) invariant the types do not
enforce.**

M4.7's decision to *defer* the `RawSpan` signature migration (A1/A2/A3) is
reasonable for **spatial** safety and ergonomics. But its justification —
*"the marked reads already trap on out-of-bounds … memory safety (no UB) is
already achieved … deferred as an ergonomic refinement, not a safety gap"* — is a
**spatial** argument. It does not cover the **temporal** hazard the `@safe` marks
on borrowed views carry. Those are different violation classes (CWE-125/787 vs
CWE-416/562), and bounds-trapping catches only the first.

## What M4.7 got right (not relitigated here)

- **Spatial safety achieved.** Raw subscripts / `loadUnaligned` trap on OOB in
  non-`-Ounchecked` builds. Correct, and the right basis to keep `-O` (not
  `-Ounchecked`).
- **Irreducible unsafe correctly surfaced and greppable** — POSIX, `mmap`/
  `madvise`, `pread`/`pwrite`, the `ADCAtomics` C shim, page arithmetic.
- **D2 upheld** — cross-process atomics stay in the C shim; Swift `Atomic` cannot
  legally alias shared mmap memory. `ReaderTable`'s `unsafe` marks are exactly
  right (`ReaderTable.swift:21`).
- **D1/D4** — the single Swift-level atomic uses explicit
  `.acquiringAndReleasing`; the five `@unchecked Sendable` types are justified
  (single-owner OS resources / cross-process-atomic discipline) and TSan-verified.

## The residual: `@safe` certifies temporal safety it cannot enforce

`@safe` is meant for a type that *owns* its storage and presents a checked
interface. It is being applied to types whose payload is a **borrowed**
`UnsafeRawBufferPointer` into a mapped page, valid only for a scan-body scope. The
tell is `RowView`'s own doc comment (`Rows.swift:35-36`):

> "Noncopyable and delivered `borrowing` … so it cannot escape."

That reasoning is false: **`~Copyable` ≠ `~Escapable`.** A `~Copyable` value can
still be `consume`d/returned out of the closure; `RowSlot` is a *class* and
escapes trivially. The "cannot escape" property is exactly what `~Escapable`
(SE-0446) would make the compiler *check* — and what `@safe` here merely asserts.

Why bounds-trapping does not save this: the mapping persists for the process, but
**freed pages are recycled** for new data (`MMap.swift:11-13`; reclamation is
gated by the reader table's generation horizon). A view read *after its snapshot
is released* therefore reads **recycled, in-bounds** memory — it does **not**
fault, it silently returns another row's bytes (CWE-416/-562). So "no UB because
reads trap" addresses spatial OOB, not this. The enforcement tool is precisely
RFC 0003 **A1**: make the views `~Escapable` over a `RawSpan` with a
`@lifetime(borrow page)` accessor — which M4.7 deferred, itself noting it needs
`@_lifetime` + `LifetimeDependence`.

Until A1 lands, these `@safe` marks are a documented convention, not a checked
fact — and `@safe` actively removes the compiler's ability to flag a future edit
that escapes one.

## Findings

| ID | Site | Class | Status today | Enforcement fix |
|---|---|---|---|---|
| **F1** | `@safe final class RowSlot` (`Executor.swift:16,20,43`) · `@safe struct RowView: ~Copyable` (`Rows.swift:37,40`) — both store a scope-bounded `UnsafeRawBufferPointer` | temporal (UAF/dangling) | latent — upheld by call-site convention; no failing test | RFC 0003 **A1**: `~Escapable` + `RawSpan` + `@lifetime`. `RowSlot` is a class → make it a struct, or stop storing the span (pass it into each `value(at:)`). |
| **F2** | `@safe enum BTree.ValueRef` (`BTree.swift:6`) · `@safe struct NodeBuilder.LeafCell`/`LeafValue` (`NodeBuilder.swift:44,156`) — `@safe` value types whose payload is a borrowed raw pointer | temporal | latent | same as F1 |
| **F3** | `@safe class MMap` exposes `public let base: UnsafeRawPointer` (`MMap.swift:14-15`); `pageBytes`/`bytes` return raw buffers (`:35,41`) | encapsulation | API too wide | **Do now, independent of A1.** Make `base` `private`; vend only the bounded accessors (ideally returning `RawSpan` w/ `@lifetime(borrow self)`). The engine invariant is real; just don't publish the naked pointer under `@safe`. |
| **F4** | `@safe class PageBuf` exposes `public let raw: UnsafeMutableRawBufferPointer` (`PageBuf.swift:4-5,29`) | temporal | latent | RFC 0003 **A3**: vend `MutableRawSpan` via `withMutableBytes`; keep `raw` internal. The buffer can outlive the owner whose `deinit` frees it. |
| **F5** | `RawSpan(_unsafeBytes:)` ×2 (`Database.swift:313,319`) | practice / API stability | lifetimes scoped correctly today | Underscored **SPI** that constructs the *safe* type via the unsafe back door (asserts the lifetime; unstable across compilers). Confine to one documented bridging helper, or use the `@_lifetime` accessor the M4.7 spike already validated. |
| **F6** | `nonisolated(unsafe)` — `Scenarios.swift:118` (bench) and `DatabaseTests.swift:168-169,237-238`, `RelationDDLTests.swift:178` (shared **mutable** vars across concurrent closures) | concurrency | **not covered by the D1/D4 audit** | Bench: prefer a `sending` binding (compiler-proves the handoff) over disabling the check. Tests: the shared mutable `var`s are genuine data races silenced by the annotation — use a `Mutex`. |

## Recommendations (priority order)

1. **Cheap, independent of the A1 deferral — do now:** F3 (`private` base), F5
   (confine `_unsafeBytes:`), F6 (tests → `Mutex`; bench → `sending`).
2. **When A1 is undeferred:** F1/F2/F4 resolve *together* — making the views
   `~Escapable` over `RawSpan` converts every `@safe`-by-assertion into
   `@safe`-by-enforcement, and removes most of the `unsafe` plumbing the slice had
   to add through the executor (`forEachRow`/`load`/`forEachRecordSpan`), because
   the spans stop being raw pointers.
3. **Interim, if A1 stays deferred:** give each `@safe` borrowed view a one-line
   `// SAFETY:` note — *"caller must not let this escape the scan-body scope; not
   compiler-enforced (Review 0001 F1)"* — so the asserted invariant is at least
   stated at the type, and add a debug-only escape tripwire if cheap.

## Severity calibration

F1/F2/F4 are **latent**, not live: today the call sites confine the views, no test
fails, TSan is clean. The risk is a *future* edit that lets a view outlive its
snapshot — which `@safe` guarantees the compiler will not flag and page recycling
guarantees will not trap. That is exactly the failure class SE-0458 + `~Escapable`
exist to make impossible, so it belongs on the ledger even with zero current
reproduction. The one-line rule: **on this codebase `@safe` is for storage-owning
types; it is currently standing in for `~Escapable` on borrowed views.**

See RFC 0003 (A1/A2/A3, D1/D2/D4) for the API references and the deferred-work
rationale this review audits.

## Resolution (2026-06)

All six findings addressed. The `Lifetimes` experimental feature (SE-0446/0456;
the flag is named `Lifetimes`, not `LifetimeDependence`, on Swift 6.4) is now on
for `ADSQLKernel`, and the two highest-exposure borrowed views — the ones that
cross into consumer/closure scopes — are genuinely compiler-enforced.

| ID | Disposition | How |
|---|---|---|
| **F3** | Fixed | `MMap.base` is `private`; only `pageBytes`/`bytes` escape the type. |
| **F5** | Fixed | Both `RawSpan(_unsafeBytes:)` sites confined to one `ReadTxn.withRawSpan` helper. |
| **F6** | Fixed | Test shared-mutable vars → `Mutex`; bench reader → `KVReader: Sendable` (not `nonisolated(unsafe)`). |
| **F1 · RowView** | **Fixed (enforced)** | `~Copyable, ~Escapable` over a `RawSpan` bound to the resolver (`bindSpan` = `_unsafeBytes` + `_overrideLifetime(borrowing: resolver)`). A view escaping the snapshot now fails to compile. |
| **F2 · ValueRef** | **Fixed (enforced)** | `~Escapable`, `.inline(RawSpan)` bound to the resolver via `BTree.boundInline`; `get` carries `@_lifetime(borrow resolver)`; `withCurrent` yields `borrowing ValueRef`. |
| **F1 · RowSlot** | Interim | `@safe` + precise `// SAFETY:` note. Column reads are decoupled from the scan body via the `@escaping` `SQLEvalEnv.column` closure (no `RawSpan` capture), so the span must be stored; enforcement would need a `RawSpan` threaded through the whole evaluator — a disproportionate refactor for a query-internal, scope-confined value. |
| **F2 · LeafCell / LeafValue** | Interim | `@safe` + `// SAFETY:` notes. Transient node-builder projections, consumed synchronously, never stored; `leafCell(page:)` has no lifetime-bearing owner to bind to. |
| **F4 · PageBuf** | Encapsulation fixed | `raw` is `internal` (was `public`) — the naked mutable pointer no longer leaves the package. The `MutableRawSpan`/`withMutableBytes` migration is deferred (≈60 in-module mutator sites), documented at the type. |

Findings the audit got exactly right and that paid off in practice: the
`~Copyable ≠ ~Escapable` point (a plain `~Escapable`-by-`_unsafeBytes` view is
*immortal* and does **not** enforce escape — the lifetime must be tied to the
snapshot owner via `_overrideLifetime`), and that `@safe` was standing in for
`~Escapable`. Where the IRON LAW's enforcement is now real (RowView/ValueRef) it
is the compiler's; where it remains an assertion (RowSlot/LeafCell/LeafValue) the
owner/lifetime/bounds are now stated at the type. All changes perf-neutral
(`sql search` ~5.0 ms, index scan ~2.1 M rows/s), 208 tests + TSan green.

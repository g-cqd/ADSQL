# RFC 0003 — Swift Memory-Safety & Performance API Adoption

Status: proposed. A catalog of Swift 6.2-generation APIs (the `Span` family,
`InlineArray`, lifetime dependencies, opt-in strict memory safety, the Swift
Collections package) and where each one lands in ADSQL — what it makes *safer*,
what it makes *faster*, and what it would only make *different*. This is a survey
+ adoption guide for a later implementer, not an implemented change. Nothing here
may alter results: the superset+residual contract (RFC 0001) and the differential
suites remain the correctness gate.

## Goals

- Shrink the **unsafe surface** on the read/scan path (raw pointers → bounds- and
  lifetime-checked spans) **without giving up zero-copy** (RFC 0002).
- Reduce **per-row heap allocation**, the documented remaining cost on the
  filtered-scan path (RFC 0002's own "future work": incremental single-column
  decode).
- Make remaining unsafe code **auditable and intentional** (strict memory safety).
- Adopt **proven data structures** where a hand-rolled one is O(n) or fiddly.
- Do all of the above **measurement-first** — the central lesson of RFC 0002.

## Conventions

Each opportunity is tagged **safety / perf / reliability**, rated **ROI** (the
expected payoff for the work) and **effort**, and pinned to a concrete site
(`file.swift:line`, symbol). "Perf" items are hypotheses until a benchmark moves;
"safety/reliability" items are adopted for correctness and should be expected to be
**perf-neutral** (do not justify them with speed).

## Baseline — already adopted (do not re-propose)

| Capability | Current state | Site |
|---|---|---|
| Noncopyable types | `RowCursor<R>: ~Copyable` | `Relation/Rows.swift:32` |
| In-process atomics | `Atomic<Bool>` double-close guard | `FileChannel.swift` |
| Cross-process atomics | C shim `adc_load_acquire_u64` / `store_release_u64` / `cas_acq_rel_u64` over an mmap'd lock file | `ReaderTable.swift`, `Sources/ADCAtomics` |
| Locks | `Mutex<Shared>`, `Mutex<[PendingWrite]>`, `Mutex<StatementCache>` | `Database.swift:46,51,58` |
| Writer exclusion | serial `DispatchQueue` + group-commit drain | `Database.swift:49`, `WriterLoop.swift` |
| Typed throws | `throws(DBError)` pervasively | `Rows.swift`, `Executor.swift`, `RecordCodec.swift` |
| Zero-copy scan | `forEachRecordSpan` passes an `UnsafeRawBufferPointer` into a per-row closure; `RowSlot` decodes lazily and caches | `Rows.swift:129`, `Executor.swift:16` |

Floor: **macOS 26**, **swift-tools 6.2** (`.swift-version` pins toolchain `6.4.0`),
**zero external dependencies**. Every API below is available at that floor unless
marked "on the horizon".

## Measurement-first principle (read before touching perf)

RFC 0002 set the cautionary tale: the *zero-copy row decode*, the original
headline hypothesis, **moved the benchmark by ~0.1 ms** (14.3 → 14.2 ms). The real
wins were algorithmic (bounded top-N; dropping residual conjuncts an index probe
already covered). After M4.6 the `sql search` benchmark stands at **5.34 ms p50 vs
SQLite 1.76 ms — 3.0× (was 8.2×)**. RFC 0002 attributes the residual 3× to:

1. the per-row index→table descent (shared with SQLite — a **floor**, not headroom), and
2. **`cellOffsets` walking and allocating the full offset table to read one
   sort-key column** — explicitly named as "a future incremental single-column
   decode."

So the highest-confidence perf lever in this RFC is **B1 (incremental
single-column decode)**, because the codebase already measured its way to it.
Everything else perf-related is a hypothesis that ships only behind an `ADSQLBench`
number. KPIs: `ADSQLBench` `sql search` p50 and the relational index-scan rows/s;
`swift test --sanitize=thread --skip-tag soak` stays green.

---

## Catalog A — Memory safety

### A1. `RawSpan` / `Span<UInt8>` on the scan path
**safety · ROI: high (safety) / neutral (perf) · effort: med-high**

`forEachRecordSpan` (`Rows.swift:129`) hands an `UnsafeRawBufferPointer` to a
per-row closure; `RowSlot` (`Executor.swift:16-74`) stores it in `private var span`
(`:20`) and decodes from it. `RawSpan` (the `Span` family, SE-0447; safe loads
SE-0525) gives identical zero-copy access that is **bounds-checked (spatial
safety)** and **lifetime-tied to the owning page (temporal safety)** — directly
retiring the footgun RFC 0002 documented: *"If body holds a reference past the
closure, it becomes a use-after-free (no safety mechanism, caller must obey
scoping)."* With a span the compiler enforces the scoping.

**The blocker to design around (easy to miss):** `Span`/`RawSpan` are `~Escapable`
(SE-0446) and **cannot be stored as a property of a `class`**. `RowSlot` is a
`final class` whose stored `span` is exactly this. A naive type swap will not
compile. Two paths:

- **(b) — recommended first, smaller blast radius.** Keep `RowSlot` a class but
  **stop storing the span**. Decode within the `forEachRecordSpan` body scope; the
  slot keeps only the materialized-`Value` cache (`[Value?]`) and the rowid. The
  span is threaded as a parameter through `value(at:)`/`compute(at:)`.
- **(a) — end state.** Convert `RowSlot` to a `~Escapable struct` carrying a
  `@lifetime(borrow page)` dependency on the page it views. Cleanest model; larger
  refactor of the executor's row environment.

**Enabling glue (required for either path):** the pager/page accessor must vend
`var bytes: RawSpan` (or `func withBytes`) annotated with a lifetime dependency
(`@lifetime(borrow self)`, SE-0446/0465). You cannot return a span out of the mmap
region without it. Convert `BTree.withValueBytes` / `Relation.withRowValue`
(`Rows.swift:145,149`) to yield a `RawSpan` instead of an `UnsafeRawBufferPointer`.

### A2. `RawSpan` in `ByteCodec`
**safety · ROI: med · effort: low-med**

`Varint.read` (`ByteCodec.swift:14`) and the `loadLE16/32/64` extensions (`:41-54`)
parse from `UnsafeRawBufferPointer` with hand-managed `offset` bounds and
`loadUnaligned`. Provide `RawSpan` overloads using its safe unaligned-load API
(SE-0525) and bounds-checked indexing; the manual `offset < bytes.count` guards
become the span's own checks. This propagates safety to every caller
(`Node.compare`, `RecordCodec.cellOffsets/decodeCell`, key compares) once A1 yields
spans. Keep the `UnsafeRawBufferPointer` overloads until callers migrate.

### A3. `MutableRawSpan` / `MutableSpan` for page writers
**safety · ROI: med · effort: med**

`PageBuf` exposes `public let raw: UnsafeMutableRawBufferPointer` (`PageBuf.swift:5`)
plus the `storeLE*` mutating extensions (`ByteCodec.swift:56-81`); every writer
(NodeBuilder, `RecordCodec.encode`, FreeList, MetaPage) writes through the raw
pointer. Expose a bounds-checked `withMutableBytes { (b: inout MutableRawSpan) in … }`
accessor (SE-0467) and migrate writers to it. The page-aligned allocation in
`PageBuf.init` (`:9-12`) is **legitimate and stays** — only the *access* becomes
safe. Same `~Escapable` rule as A1: vend via accessor/closure, never store the span.

### A4. Opt-in strict memory safety (`StrictMemorySafety`)
**reliability · ROI: high · effort: med (annotation churn) · sequence last**

SE-0458 (Swift 6.2) adds an opt-in mode (`swiftSettings: [.strictMemorySafety()]`,
or `-strict-memory-safety`) that diagnoses every use of an unsafe construct and
requires an explicit `unsafe` marker. For an engine that *deliberately* uses
unsafe primitives, this converts the unsafe surface from "implicit and scattered"
to "**explicit, greppable, reviewed**" — each surviving `unsafe` is a documented
decision, and new unsafe code can't sneak in. Adopt **after** A1–A3 have shrunk the
surface, so the annotation burden is small. Roll out per-target (Kernel first).

### A5. `InlineArray<N, T>` for fixed-width stack scratch
**perf · ROI: med · effort: low**

SE-0453 (Swift 6.2) gives a fixed-size, inline-stored, ARC-free array with
`.span`/`.mutableSpan` views. Targets: varint encode scratch (`≤10` bytes), the
8-byte rowid / LE64 staging, fixed index-key prefixes, and XXH64 block buffers —
anywhere a short, statically-bounded `[UInt8]` is allocated transiently. Replaces
heap `[UInt8]` with stack storage and feeds A2/A3 spans directly.

### A6. `withUnsafeTemporaryAllocation` for transient per-call buffers
**perf · ROI: low-med · effort: low**

SE-0322 (generalized for `~Escapable` in SE-0437) provides a scoped uninitialized
buffer with no heap allocation. Use where a short-lived buffer is built and
discarded inside one call — sort-key assembly, record encode staging — pairing with
`OutputRawSpan` (B3). Only worthwhile where the buffer does **not** escape.

---

## Catalog B — Performance & allocation reduction

### B1. Incremental single-column decode  ★ codebase-endorsed next lever
**perf · ROI: high · effort: med**

`RecordCodec.cellOffsets` (`RecordCodec.swift:66`) allocates a fresh `[Int]` of
*every* stored cell's offset per row — even when the scan needs one column (a
sort-key, a residual predicate). `RowSlot.ensureOffsets` (`Executor.swift:68`)
caches it per row but still pays one `[Int]` allocation and an O(ncols) walk each
row. RFC 0002 names this exact cost as the remaining filtered-scan overhead.

**Proposal:** decode the *i*-th cell by skipping `i-1` cells from the record start
(reusing `skipOne`, `RecordCodec.swift:132`) without building the full offset
table; or hold the offsets in a **row-lifetime reused scratch** (`InlineArray<N,
Int>` for small column counts, or a `MutableSpan<Int>` over a buffer owned by the
executor and reused across rows) instead of allocating per row. For a
sort-key-only scan this removes both the `[Int]` allocation and the work of
locating trailing columns. Ship behind the `sql search` benchmark.

### B2. Borrowed `ValueRef` + `UTF8Span` for compare-without-materialize
**perf · ROI: high · effort: high**

Today decoding a TEXT/BLOB cell allocates: `RecordCodec.decodeCell` builds a
`String` (`RecordCodec.swift:118`, `String(decoding:as:)`) or copies a `[UInt8]`
(`:123`) **before** any predicate runs. The executor's comparison path is already
allocation-free once it *has* a `String` (`SQLCompare.compareUTF8` iterates
`a.utf8`, `Eval.swift:74-95`) — but the `String` itself was allocated at decode.
For a column that is **compared but not projected**, or a row the WHERE rejects,
that allocation is pure waste.

**Proposal:** a `~Escapable` `ValueRef` that, for text/blob, holds a
`RawSpan`/`UTF8Span` (SE-0464) into the page and materializes an owned
`String`/`[UInt8]` **only when the value escapes into the output row**. WHERE /
ORDER BY comparators operate on bytes directly (BINARY = UTF-8 byte compare;
NOCASE = ASCII fold on the fly, mirroring `compareUTF8NoCase`). Net effect:
**zero allocation for filtered-out and compare-only text/blob columns.** Phase it:
(i) byte/`UTF8Span` comparators alongside the existing `String` ones; (ii) lazy
`ValueRef` in `Eval`; (iii) materialize at projection only. Highest-effort item
here; gate strictly on a benchmark.

### B3. `OutputRawSpan` / `MutableRawSpan` on the write path
**perf · ROI: med · effort: med**

`RecordCodec.encode` (`RecordCodec.swift:21`) grows a `var out: [UInt8] = []` and,
for text, allocates a throwaway `Array(s.utf8)` (`:37`) before appending.
`Varint.append(to: inout [UInt8])` (`ByteCodec.swift:4`) appends to a growing
array. Encoding into a pre-sized `OutputRawSpan` (SE-0485) or a `MutableRawSpan`
view of the destination page avoids the intermediate array and its reallocations,
and `s.utf8` can be written directly (drop the `Array(s.utf8)` copy). RFC 0002
flagged write-path `insertAssembled` headroom as out of scope; this is its API.

### B4. `ContiguousArray` for the hot row buffers
**perf · ROI: low-med · effort: low**

The accumulator's `[[Value]]`, per-row projection `[Value]`, and ORDER BY sort-key
arrays (`Executor.swift`, `Accumulator`) are `Array`. `ContiguousArray<Value>`
guarantees native contiguous storage (no Cocoa-bridging check on element access)
and exposes a clean `.span`. Low-risk swap on the inner-loop buffers only; measure
— the gain is small and only worth it on the hottest arrays.

### B5. Cross-module inlining of the decode primitives
**perf · ROI: med · effort: low**

The varint / LE-load / `cellOffsets` / `decodeCell` primitives live in
`ADSQLKernel` but the scan loop is driven from `ADSQL`. Mark the hot primitives
`@inlinable` (+ `@usableFromInline` on their helpers), or enable cross-module
optimization for the package, so the per-cell decode inlines into the scan loop
instead of paying a cross-module call per cell.

### B6. SIMD for byte scanning  (not on the user's original list — flagged)
**perf · ROI: med · effort: med-high**

`SIMD16<UInt8>` / `SIMD32<UInt8>` can vectorize varint-terminator search, UTF-8
validation (feeding B2's `UTF8Span`), and `memchr`-style scanning inside LIKE/GLOB.
A realistic accelerant for filtered scans **after** B1/B2 remove the allocation
overhead that currently dominates. Keep scalar fallbacks; benchmark per shape.

---

## Catalog C — Collections (Swift Collections — recommended, cost noted per type)

Adopting `swift-collections` ends the zero-dependency stance. Recommendation:
add it for the **high-ROI types below**, each independently justifiable; for a
single type, **vendoring just that file** is a legitimate alternative that keeps
the dep count at zero. Decide per row.

| Type | Site | Current cost | Win | ROI | Dependency note |
|---|---|---|---|---|---|
| **`Deque`** | writer queue `Mutex<[PendingWrite]>` (`Database.swift:51`); drain `queue.removeFirst(take)` (`WriterLoop.swift:68`) | `removeFirst` shifts the array — **O(n)** per drain | O(1) head removal | **high** (modest absolute: depth ≈ concurrent writers, drained in batches) | small, self-contained |
| **`OrderedDictionary`** | statement cache (`Statement.swift:306-332`): `entries` + parallel `order: [String]` using `firstIndex(of:)`/`remove(at:)`/`removeFirst()` — **O(n) per access** | replaces both fields; O(1) move-to-front + eviction; deletes the hand-rolled LRU | **high** | also unifies GROUP BY's `groups` dict + parallel `order: [GroupKey]` (`Executor.swift:449-450`) |
| **`Heap`** (min-max) | bounded top-N ORDER BY+LIMIT (`Accumulator.insertSorted`) | binary-search insert shifts an array — O(k) | O(log k) insert/pop-max | med | only wins for large `k`; small-`k` array is fine — benchmark |
| **`BitSet`** | rowid dedup `Set<Int64>` (`Executor.swift:192,559`) | hashed set, 1 bucket/row | dense-rowid dedup: far smaller + faster | med | best when rowids are dense |
| **`OrderedSet`** | DISTINCT `Set<GroupKey>` (`Executor.swift:668`) | set, then a later sort to restore order | deterministic order, drop a sort | low-med | |

**Swift Algorithms** (ergonomics, lower ROI): `uniqued()` (DISTINCT), `chunked`
(group-commit batching), `minAndMax`. Optional; not load-bearing.

---

## Catalog D — Concurrency & reliability

### D1. Explicit atomic memory orderings — reliability · ROI: med · effort: low
The in-process `Atomic` usage (`FileChannel.closed`) should pass explicit orderings
(`.acquiring` / `.releasing` / `.acquiringAndReleasing`) rather than defaults, so
intent is on the page — matching the acquire/release discipline already explicit in
the C shim.

### D2. Keep the `ADCAtomics` C shim — **explicit non-goal to remove it**
This is a guard against a plausible but wrong "modernization." `Synchronization.Atomic<T>`
operates on Swift-managed storage; it cannot legally alias bytes at a fixed address
inside a **cross-process** mmap'd region. The reader table publishes per-slot
generations via `adc_*` on shared memory (`ReaderTable.swift`); the C shim is the
**correct** tool. Do not replace it with stdlib `Atomic`.

### D3. Complete typed-throws adoption — reliability · ROI: low-med · effort: low
`throws(DBError)` (SE-0413) is already pervasive. Audit the remaining untyped
`throws` (mostly at the public API boundary and IO) and tighten where the error
domain is in fact `DBError`, keeping error paths explicit and existential-free.

### D4. `Sendable` audit — reliability · ROI: med · effort: low-med
Re-examine each `@unchecked Sendable` (`Pager`, `FileChannel`, `MMap`,
`WriterLoop.PendingWrite` at `WriterLoop.swift:13`). Where Span-based immutability
(post-A1) makes thread-safety *provable*, move to checked `Sendable`; otherwise pin
each with a one-line invariant comment so the `@unchecked` is a documented promise,
not a silence.

### D5. `WordPair` (double-word CAS) — situational
Only relevant if a future lock-free structure needs ABA protection. Noted, not
prescribed.

### D6. Async is mostly N/A — **manage expectations**
This is a synchronous, mmap-backed engine with a single serial writer; the hot path
must **stay synchronous** (async/await adds suspension overhead with no benefit
here). **Swift Async Algorithms has no hot-path role.** Two narrow, optional
exceptions worth noting only: (i) an `AsyncSequence` row-streaming *public* API for
consumers who want backpressure; (ii) swapping the serial-writer `DispatchQueue`
for an `actor` — a lateral move with `Sendable` churn, **not** recommended now.

---

## Catalog E — Build settings & toolchain

- Stage `.strictMemorySafety()` into `swiftSettings` per target (A4); confirm
  `-strict-concurrency=complete` is in force under the 6.2 tools.
- Enable cross-module / whole-module optimization for the hot decode path (B5).
- **Do not adopt `-Ounchecked`.** It strips bounds checks — the opposite of this
  RFC's intent. Span's checks plus `-O` are the model; keep the checks.
- Optional defense-in-depth for the shipped `adsql` process: the
  `com.apple.security.hardened-process.hardened-heap` entitlement.

## On the horizon (note; do not adopt yet)

The toolchain is pinned at 6.4, so watch: `SpanIterator` (macOS 27), `Iterable` /
borrowing-sequence (SE-0516, in review 2026-06 — a `~Escapable`/`~Copyable`-friendly
iteration protocol that would let span-based row sources conform to a standard
sequence), yielding accessors (SE-0474, accepted — `_read`/`_modify` coroutine
accessors useful for the page/`PageBuf` views), `Optional` noncopyable
improvements (SE-0532, in review).

---

## Highest-ROI shortlist (lead here)

1. **B1 — incremental single-column decode.** The codebase already measured its way
   to this; kills the per-row `cellOffsets` `[Int]` allocation. *(perf, behind bench)*
2. **B2 — borrowed `ValueRef` + `UTF8Span`.** Removes decode allocations for
   compared-but-not-projected and filtered-out text/blob columns. *(perf, behind bench)*
3. **A1 — `RawSpan` scan path** (+ the `RowSlot` `~Escapable` redesign and the
   lifetime-annotated page accessor). *(safety; expect perf-neutral)*
4. **A4 — opt-in strict memory safety**, after A1–A3. *(reliability)*
5. **C — `OrderedDictionary` (statement cache, GROUP BY) + `Deque` (writer queue).**
   Deletes O(n) hand-rolled code. *(reliability/perf)*

### Suggested phasing
- **Phase 1 (safety, perf-neutral):** A2 → A1 (path b) → A3. Lifetime-annotated page
  accessor; spans replace raw pointers; TSan + differential suites stay green.
- **Phase 2 (perf, benchmarked):** B1, then B2; B5 alongside. Each gated on
  `ADSQLBench`.
- **Phase 3 (hardening):** A4 strict memory safety; D1/D3/D4 audits.
- **Phase 4 (collections):** C `OrderedDictionary` + `Deque` (decide adopt vs.
  vendor); revisit `Heap`/`BitSet` only if a benchmark calls for them.
- **Opportunistic:** A5/A6/B3/B4 as the relevant code is touched.

## Risks & non-goals

- **No result change, ever.** Every item is held by the RFC 0001 superset+residual
  contract and the differential fuzzers; a regression surfaces as a loud mismatch.
- **Span ≠ speed.** A1/A3 are safety migrations; do not justify or measure them as
  perf wins (RFC 0002's lesson).
- **Keep the C atomics shim** (D2). **No `-Ounchecked`** (Catalog E). **Async stays
  off the hot path** (D6).
- **The `~Escapable`-in-a-class constraint** (A1) is a real refactor, not a syntax
  swap — budget for it.

## Verification & acceptance

1. **Correctness gate (unchanged):** `swift test` (differential suites vs CSQLite)
   + `swift test --sanitize=thread --skip-tag soak`. Every change keeps both green.
2. **Perf gate:** `swift run -c release ADSQLBench --rows 100000 sql search` (and
   the relational index-scan scenario), both engines, before/after. A "perf" item
   that does not move its named scenario is not landed as a perf win.
3. **Safety gate:** after A4, the build is clean under `-strict-memory-safety`, and
   every surviving `unsafe` has a rationale comment.
4. **API citations** (verified against Apple's offline docs / Swift Evolution):
   Span SE-0447 · nonescapable SE-0446 / stdlib primitives SE-0465 ·
   MutableSpan/MutableRawSpan SE-0467 · OutputSpan SE-0485 · UTF8Span SE-0464 ·
   RawSpan safe loads SE-0525 · `extracting()` SE-0488 · InlineArray SE-0453 ·
   noncopyable SE-0390 / generics SE-0427 / stdlib primitives SE-0437 ·
   borrowing/consuming SE-0377 · strict memory safety SE-0458 · temporary buffers
   SE-0322 · typed throws SE-0413. `Synchronization` (Atomic/Mutex) macOS 15+;
   the `.span`/`.mutableSpan` properties on `Array`/`ContiguousArray`/`Data` are
   macOS 26. All satisfied by the macOS 26 / Swift 6.2 floor.

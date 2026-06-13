# RFC 0005 — Apple-Native API Adoption (+ a re-challenge of prior findings)

Status: proposed. A focused pass over **Apple-native APIs ADSQL does not yet leverage** —
SDK frameworks, Apple/`swiftlang` GitHub packages, and (last resort) Point-Free — and a
deliberate **re-test of two conclusions from RFC 0003/0004** through that lens. Companion
to RFC 0003 (Swift memory-safety/perf stdlib APIs), RFC 0004 (the performance program), and
Review 0002 (the evidence). Researched via the offline apple-docs index + source-traced
package review; nothing here changes code.

The headline is not a list of missing calls — it is a **correction**: RFC 0003 D2's stated
reason for keeping the hand-written C atomics shim was wrong (§Challenges 1). And the
framing itself is corrected: ADSQL's **syscall layer is already mature**; the real gaps are
higher-level frameworks plus one packaging re-decision.

## Already leveraged — credit (and why the premise needs challenging)

Before recommending anything, the honest baseline — these are *already* used, do not
re-propose them:

| Apple-native API | Use | Site |
|---|---|---|
| `clonefile(2)` | O(1) APFS atomic snapshot (writer quiesced) | `Integrity.swift:165` |
| `fcntl(F_PREALLOCATE)` + `F_ALLOCATECONTIG`/`F_ALLOCATEALL` | contiguous file growth | `FileChannel.swift:139` |
| `fcntl(F_NOCACHE)` | UBC bypass for bulk load | `FileChannel.swift:153` |
| `fcntl(F_BARRIERFSYNC)` / `F_FULLFSYNC` | durability profiles | `FileChannel.sync:120` |
| `mmap` + `madvise(MADV_RANDOM)` | zero-copy reads, no read-ahead pollution | `MMap.swift` |
| `Synchronization` `Mutex` / `Atomic` (explicit orderings) | in-process state, double-close guard | `Database.swift`, `FileChannel.swift:158` |
| `~Copyable` cursors; `-strict-memory-safety` | ownership + audited unsafe surface | RFC 0003 |

**Implication:** the POSIX/Darwin surface is well-exploited. The opportunities below are
*frameworks* and a *package re-decision*, not more syscalls.

## Catalog — Apple-native APIs not yet leveraged

Tags: **fit** (yes / partial / no), **ROI / effort / risk**.

### T1 · Unified logging + signposts — `os.Logger` + `OSSignposter`  *(fit: yes; ROI: high; effort: low; risk: none)*
There is **no logging or signpost instrumentation** in the tree. `OSSignposter` (macOS 12)
+ `os.Logger` (macOS 11) integrate directly with **Instruments** (Points of Interest, the
`os_signpost` timeline). Wrap the hot intervals — table/index scan, the index→rowid→table
descent, `Committer.commit`, the group-commit drain — in `beginInterval`/`endInterval`.
- **Why it's first:** it is the *measurement substrate* for RFC 0004. Today `ADSQLBench`
  times with ad-hoc `nowNanos()`; signposts turn RFC 0004's P0 "profile the descent" into a
  real Instruments trace, and make every "did this perf change move the number?" honest.
- Keep it cheap: `OSSignposter` is near-free when the subsystem isn't being recorded; can be
  compiled out of release if desired.
- Refs: `os/ossignposter`, `os/ossignpostid`, `os/logger`, `os/logging`.

### T1 · `import System` (SDK framework, zero new dependency)  *(fit: partial; ROI: med; effort: med; risk: low)*
`FileChannel.swift` uses raw `Darwin.open/pread/pwrite/lseek/ftruncate/fstat` with manual
`throwErrno`. The SDK ships the **`System`** framework (`FileDescriptor`, `FilePath`,
`Errno`, `FilePermissions`, `throws(Errno)`, positional `read(fromAbsoluteOffset:)` /
`write(toAbsoluteOffset:)`). Adopting `import System` gives typed errno + a typed fd with
**no package dependency** (it's in the SDK — consistent with the zero-dep stance).
- **Partial by necessity:** `System` does **not** wrap `fcntl` (so
  `F_BARRIERFSYNC`/`F_FULLFSYNC`/`F_PREALLOCATE`/`F_NOCACHE` stay raw `Darwin`), nor
  `mmap`/`madvise`/`pwritev`/`clonefile`. So this cleans up the basic fd/errno layer only;
  `MMap.swift`, the durability path, and `pwritev` remain `Darwin`. Net: ergonomics, not a
  Darwin-removal.
- Refs: `system/filedescriptor`, `system/errno`, `system/filepath`.

### T2 · Accelerate / vDSP / Swift SIMD  *(fit: yes (consumer) / partial (engine); ROI: med–high; effort: med; risk: low; benchmark-gated)*
The apple-docs consumer runs a **Hamming shortlist + int8 vector rescore** over BLOB columns
(`vec_bin`/`vec_i8`) in application code (ROADMAP) — exactly what **Accelerate** (`vDSP_dotpr`,
BNNS int8 paths) and Swift's `SIMD` types are for. Two angles:
1. *Consumer-facing:* document/expose fast BLOB access so the rescore uses Accelerate (the
   ROADMAP already says ADSQL needs "fast BLOB scans + batched `IN` fetches", which it has).
2. *Engine:* SIMD predicate evaluation for the zone-map/scan path (RFC 0004 P1.3), and
   branch-free SIMD scanning for UTF-8 / varint boundaries (Review 0002 §SOTA, Zhou & Ross).
- Strictly behind a benchmark; SIMD wins are real on contiguous bytes but easy to overclaim.
- Refs: `accelerate/vdsp_dotpr`, Swift `SIMD`.

### T2 · Compression framework — LZFSE / LZBITMAP / LZ4  *(fit: situational; ROI: situational; effort: med; risk: med; benchmark-gated)*
No compression today. The corpus is text-heavy (~580 B rows); compressing overflow pages or
large values trades CPU for file size and **fewer page faults** (the dominant mmap cost,
Review 0002 §mmap). `COMPRESSION_LZFSE` is Apple-recommended; `COMPRESSION_LZBITMAP` is
tuned for the vector unit. Make it opt-in per-table (or overflow-only) and prove it on
`ADSQLBench`; decompression sits on the read hot path, so it can easily be a net loss for
warm/cached workloads.
- Refs: `compression/compression_lzfse`, `compression/compression_lzbitmap`, `compression/compression_lz4_raw`.

### Packages (weighed against the zero-dependency stance)

| Package | Verdict |
|---|---|
| **apple/swift-atomics** (`UnsafeAtomic`) | **Sound** replacement for the `ADCAtomics` C shim (§Challenges 1). Trade: retires hand-written C + typed orderings **vs.** ADSQL's first external dependency. |
| **apple/swift-system** | Same API as the SDK `System` framework → **prefer the SDK framework** (zero dep). The package adds nothing the SDK doesn't. |
| **apple/swift-collections** (beyond RFC 0004) | Only `TrailingArray`/`TrailingElementsModule` (stable; header+trailing-bytes managed buffer) is topically interesting, and only if page/record buffers were *managed Swift memory* — they are mmap/`PageBuf`, so it doesn't fit. `RigidArray`/`RigidDeque` (fixed-capacity, noncopyable) could back a future buffer pool. `SortedCollections` (B-tree) is explicitly **not production-ready**. |
| **apple/swift-numerics**, **apple/swift-algorithms** | Nothing core; convenience only. |
| **Point-Free (last resort): nothing for the engine.** | `swift-structured-queries` is a SQL *string builder* (a typed DSL that would sit *above* ADSQL, not inside it); `sqlite-data` wraps GRDB/SQLite (a competitor to replace, not embed); `swift-parsing` could build the SQL tokenizer but hand-written recursive-descent wins and stays zero-dep. |

## Challenges to prior findings

**1 · RFC 0003 D2 — "keep the C atomics shim; Swift `Atomic` can't alias shared mmap." → the *reason* is wrong.**
The claim holds for **stdlib `Synchronization.Atomic`** (it owns its storage; you can't place
it at a chosen mmap offset across processes). It does **not** hold for the **swift-atomics
package's `UnsafeAtomic<UInt64>(at:)`**: it is constructed over a caller-owned
`UnsafeMutablePointer<UInt64.AtomicRepresentation>` and lowers to address-based hardware
atomics (`Builtin.atomicload/atomicstore/cmpxchg` on the raw pointer → ARM64 LDAR/STLR/CAS)
with **no thread- or process-local state** — i.e. exactly equivalent to C11 `_Atomic uint64_t`
over a `MAP_SHARED` region, the canonical way to do cross-process atomics. So `UnsafeAtomic`
**can** replace `ADCAtomics` on the reader table (`ReaderTable.swift`).
- **Revised conclusion:** keeping the shim may still be right — but only on **dependency
  hygiene** (it's tiny, in-tree, proven, zero external deps), *not* on capability. Decide on
  that axis. If adopted, honor: 8-byte slot alignment in the lock file, one-time non-racy
  initialization, and a code comment noting the (sound but Apple-undocumented) reliance on
  shared-memory atomic semantics.

**2 · RFC 0004 — "the full root→leaf COW page copy is an inherent cost." → challenged, original stands (honest negative).**
The Apple-native temptation is mach `vm_copy` / `vm_remap` to make `PageBuf(copying:)`
(16 KiB memcpy) a *lazy* VM-level copy-on-write. Investigated → **no fit**: a page is shadowed
*because it is about to be mutated*, so lazy VM-COW would fault-and-copy almost immediately
anyway, and a mach VM operation (~µs) costs more than a 16 KiB memcpy (~hundreds of ns) on
Apple Silicon. This **reinforces** RFC 0004: the lever is *fewer* copies (bigger group-commit
batches, avoid the request double-clone), not VM trickery.

**3 · The premise "ADSQL under-uses Apple-native APIs." → challenged.**
The syscall layer is already mature (clonefile, F_PREALLOCATE, F_NOCACHE, barriers, madvise —
see the credit table). The genuine, unleveraged surface is *frameworks* (observability,
Accelerate, Compression) and the *atomics-package re-decision* — not POSIX.

## Prioritized recommendations (measurement-first, zero-dep-aware)

- **P0 — `OSSignposter`/`Logger` instrumentation** (T1). Risk-free and unblocks every
  measurement RFC 0004 depends on. Do this first.
- **P1 — `import System`** ergonomics for `FileChannel`'s basic fd/errno ops (zero-dep,
  partial). Separately, **re-decide swift-atomics vs. `ADCAtomics`** on dependency grounds
  (§Challenges 1) — capability is no longer the blocker.
- **P2 (benchmark-gated)** — Accelerate/SIMD for the consumer's vector rescore and the
  zone-map/scan predicate path (T2); Compression as an opt-in per-table experiment (T2).
- **No-go / documented** — `vm_copy` COW (§Challenges 2); Point-Free packages; swift-numerics;
  any new external dependency whose win isn't proven.

## Risks & non-goals

- **Zero-dependency tension.** swift-atomics / swift-system as *packages* would be ADSQL's
  first external dependency. Prefer the SDK `System` framework (zero dep); treat swift-atomics
  as a deliberate, separately-justified call.
- **Measurement-first.** Compression and Accelerate ship only behind an `ADSQLBench` number
  that moves; the P0 signposts exist precisely to keep those claims honest (the RFC 0002 lesson).
- **Don't** re-recommend already-used syscalls, undo the COW/mmap design, or take an engine
  dependency on a query-builder or a SQLite wrapper.

## Verification

- Every adopted item names a real current-gap site (`FileChannel.swift`, `ReaderTable.swift`,
  `MMap.swift`, `ADSQLBench`); each perf item names the `ADSQLBench` scenario it must move,
  validated by an Instruments signpost trace.
- `swift test` + `swift test --sanitize=thread --skip-tag soak` stay green for any change a
  later implementation makes (esp. a swift-atomics swap on the reader table — TSan + the
  cross-process tests are the gate).
- Self-check: numbered 0005, house style matches RFC 0001–0004, the Challenges section is
  present and honest (including the negative `vm_copy` result and the corrected D2 reasoning).

## References

Apple SDK (offline apple-docs index): `os/ossignposter`, `os/ossignpostid`, `os/logger`,
`os/logging` · `system/filedescriptor`, `system/errno`, `system/filepath` ·
`accelerate/vdsp_dotpr` · `compression/compression_lzfse`, `compression/compression_lzbitmap`,
`compression/compression_lz4_raw`.

Apple / swiftlang packages: github.com/apple/swift-atomics (`UnsafeAtomic`,
`AtomicMemoryOrderings`) · github.com/apple/swift-system · github.com/apple/swift-collections
(`TrailingElementsModule`, `RigidArray`) · github.com/apple/swift-numerics ·
github.com/apple/swift-algorithms.

Point-Free (assessed, not adopted): github.com/pointfreeco/swift-structured-queries ·
github.com/pointfreeco/sqlite-data · github.com/pointfreeco/swift-parsing.

Cross-refs: RFC 0003 (Swift memory-safety/perf APIs, incl. D2), RFC 0004 (performance
program), Review 0002 (performance & architecture), Review 0001 (`@safe`/Span audit).

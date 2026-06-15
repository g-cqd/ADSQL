# RFC 0010 — apple-docs read-engine integration

**Status:** Active (driving program) · **From:** apple-docs (documentation-search server) ·
**To:** ADSQL (`g-cqd/adsql`)
**Goal:** replace the SQLite read engine behind apple-docs `/search` with ADSQL, and collapse the
apple-docs↔ADSQL boundary ("hopping") cost to near zero.

> This RFC owns the *detail* of the program. `ROADMAP.md` owns the *priority* — it lists **M8** as the
> driving milestone and points here. Per-feature state claims (PRESENT / PARTIAL / ABSENT) are grounded
> in the cited source files, not aspirational.

---

## 1. Why

Measured baseline (apple-docs RFC 0007 F4): the HTTP engine is fine (`/healthz` ~35k req/s), but
`/search` **ceilings at ~32 req/s** under concurrency — a query that's ~28 ms alone inflates ~4× under
8-way load (only ~395% CPU = ~4 of 8 cores), the **memory-bandwidth / cache-contention** signature of
8 threads scanning the 4 GB SQLite corpus: `FTS5 MATCH → JOIN the row-store documents table → bm25 + a
scalar CASE tier + 13 filter predicates`. SQLite is already tuned (WAL, NOMUTEX, 10 GB mmap, per-thread
connections) — the ceiling is structural.

ADSQL targets this directly: **wait-free-reader MVCC** (readers never block, never contend on a lock) +
**block-max WAND ranked top-k** (already ~2.3× SQLite FTS5) + **covering-index serving** (index-only,
tiny working set) + **zero-copy row views** (`RawSpan` over the mmap'd page, no per-row allocation).

### 1.1 The formal adoption gate (apple-docs RFC 0001 · P5 `records.md`)

apple-docs runs on **Bun** (`bun:sqlite`), and its own Swift-native transition **already built the
integration seam**: a `bun:ffi` dlopen of **`libAppleDocsCore.dylib`** behind a **frozen `ad_storage_*`
C ABI** (`ad_storage_open` / `_close` / `_search_pages`, ABI v1; `swift/Sources/ADCore/StorageExports.swift`),
where the engine *today* is a dlopen'd `libsqlite3` via `swift/Sources/CSQLiteShim`. **ADSQL's job is to
become the engine *inside* that dylib** — there is no new bridge to design; A3 (`searchFramed`) lands as
the body of `ad_storage_search_pages`, and the wire format in §2.5 is that ABI.

apple-docs RFC 0001 gates ADSQL adoption (its P7) on **three explicit conditions**:
1. **FTS5 + bm25** — ✅ **HAVE.** bm25f score parity **and** ranked-order parity now proven against
   SQLite FTS5 through the importer (F2 below, landed).
2. **Linux x64/arm64** — ❌ **NOT MET — the #1 blocker.** apple-docs is first-class Linux; ADSQL's
   IO/durability layer is Darwin-specific (`mmap`, `F_BARRIERFSYNC`/`F_FULLFSYNC` via `fcntl`, APFS
   `clonefile`, the cross-process reader table). This RFC previously mis-scoped portability as
   "de-risked" — that referred only to macOS arm64+x86_64. **Linux is the largest gate item.** See §4.0.
3. **real-SQLite → ADSQL corpus migration** — ✅ **F1 importer DONE.** The live `.db` that the
   `bun:sqlite` writer mutates can't be opened in place, so the migration is offline — exactly F1's shape.

**Scalar/JSON surface** (`Sources/ADSQLKernel/SQL/Functions.swift`) already implements the query's
functions with SQLite-matching semantics (`COALESCE`, `LOWER`/`UPPER`, `LENGTH`/`INSTR`/`SUBSTR`,
`JSON_EXTRACT`, `CAST`, `LIKE`, `||`, `COLLATE NOCASE`). The `json_each` filter (`d.source_type IN
(SELECT value FROM json_each($sources_json))`) uses the **contracted `IN (SELECT … json_each …)` shape**,
which ADSQL evaluates self-contained via its `inJSONEach` AST node + `SQLJSON.eachValues` — **not** the
general FROM-clause table-valued `json_each` of RFC 0011. **The entire apple-docs main query (§2.2–2.4) is
now proven byte-identical to SQLite** (`Tests/ADSQLImportTests/AppleDocsMainQueryTests.swift`), so the hot
path has **no SQL-surface gap**; the open P0a items are F0 Linux + the INT engine swap.

---

## 2. The workload contract (what ADSQL must serve)

### 2.1 Read schema

| Object | Shape | Notes |
|---|---|---|
| `documents` | ~350k rows, ~200 MB | base table; rowid (`id`) joins the FTS tables |
| `roots` | ~100–200 | `slug`, `display_name` — the framework LEFT JOIN |
| `documents_fts` | FTS5 | `(title, abstract, declaration, headings, key)`, `tokenize='porter unicode61'` |
| `documents_trigram` | FTS5 external-content | `content='documents'`, `content_rowid='id'`, `tokenize='trigram case_sensitive 0'` (indexes `title`) |
| `documents_body_fts` | FTS5 (optional) | `(body)`, `tokenize='porter unicode61'` |

Columns the read path reads from `documents`: `id, key, title, role, role_heading, abstract_text,
declaration_text, platforms_json, min_ios..min_visionos (TEXT), min_ios_num..min_visionos_num (INTEGER),
framework, source_type, source_metadata (JSON TEXT), url_depth, is_release_notes, is_deprecated,
is_beta, kind, language`.

### 2.2 The four query tiers (byte-parity-pinned to apple-docs `search.js`)

**Main FTS** (the hot path), bm25 weights **(10,5,3,2,1)** over `(title,abstract,declaration,headings,key)`:
```sql
SELECT <24 projection cols>,
  bm25(documents_fts, 10.0, 5.0, 3.0, 2.0, 1.0) AS rank,
  CASE WHEN LOWER(d.title)=LOWER($raw) THEN 0
       WHEN LOWER(d.key)=LOWER($raw)   THEN 0
       WHEN LOWER(d.title) LIKE LOWER($raw)||'%' THEN 1
       WHEN INSTR(LOWER(d.title), LOWER($raw))>0 THEN 2
       ELSE 3 END AS tier
FROM documents_fts
JOIN documents d ON documents_fts.rowid = d.id
LEFT JOIN roots r ON r.slug = d.framework
WHERE documents_fts MATCH $query
  <13 filter predicates>
ORDER BY tier, rank LIMIT $limit;
```
- **Title-exact:** `FROM documents d … WHERE d.title=$raw COLLATE NOCASE … ORDER BY tier, CASE WHEN
  d.role='symbol' OR d.kind='symbol' THEN 0 ELSE 1 END, length(d.key) LIMIT $limit` (rank=0, tier=0).
- **Trigram:** `FROM documents_trigram … WHERE documents_trigram MATCH $query … LIMIT $limit`.
- **Body:** `FROM documents_body_fts … bm25(documents_body_fts,1.0) AS rank … ORDER BY rank LIMIT $limit`.

### 2.3 Projection — 24 columns, fixed positional order (the JS decoder is positional)
```
path, title, role, role_heading, abstract, declaration, platforms,
min_ios, min_macos, min_watchos, min_tvos, min_visionos,
framework(=COALESCE(r.display_name,d.framework)), root_slug(=COALESCE(r.slug,d.framework)),
source_type, source_metadata, url_depth, is_release_notes, is_deprecated, is_beta,
doc_kind(=d.kind), language, rank, tier
```

### 2.4 Filters — the 13 predicates (params bound per request, each NULL-guarded ⇒ NULL param passes)
`framework` (=), `source_type` (=), `sources_json` (`d.source_type IN (SELECT value FROM
json_each($sources_json))`), `kind` (LOWER-match over role_heading/kind/role), `language`
(=/NULL/'both'), `year` (`CAST(json_extract(source_metadata,'$.year') AS INTEGER)=$year`), `track_like`
(`LOWER(COALESCE(json_extract(source_metadata,'$.track'),'')) LIKE $track_like`), `deprecated_mode`
(include/exclude/only over `is_deprecated`), and `min_ios..min_visionos` (5× `min_*_num IS NULL OR
min_*_num <= $min_*`).

### 2.5 FFI wire format (the boundary contract)

**Request** `ad_storage_search_pages`:
`[u32 version=1][u64 handle][nstr query][nstr raw][u32 limit]` then the 13-field filter bag:
`framework,source_type,sources_json,kind,language` as `nstr`, `year` as `nu64`, `track_like,
deprecated_mode` as `nstr`, `min_ios,min_macos,min_watchos,min_tvos,min_visionos` as `nu64`.
- `nstr` = `[u32 len][utf8]`, `len=0xFFFFFFFF` ⇒ NULL. · `nu64` = `u64`, `0xFFFF…FFFF` ⇒ NULL.

**Response** (the framed rows): `[u32 colCount][u32 rowCount]` then `rowCount × colCount` cells; each
cell `[u8 tag][payload]`: `0`=NULL, `1`=INT `[i64 LE]`, `2`=REAL `[f64 LE]`, `3`=TEXT `[u32 len][utf8]`,
`4`=BLOB `[u32 len][bytes]`. All little-endian.

---

## 3. Current-state map (evidence-based)

| Feature | State | ADSQL seam it builds on / where it lands |
|---|---|---|
| **F0** Linux x64/arm64 **[GATE]** | **✅ DONE** | Glibc forks landed; **`swift build` + the full `swift test` differential suite pass on x64+arm64** in CI — runtime-validated (clonefile→byte-copy snapshot, `fdatasync`/`fsync`, `posix_fallocate`, the cross-process reader table, XSI `strerror_r`). The CI lane stays advisory only because it tracks the moving nightly tag (the manifest needs 6.3 features); pin + require once a stable ≥6.3 toolchain ships |
| **INT** `ad_storage_*` engine swap **[GATE]** | **ABSENT** | implement the frozen `ad_storage_search_pages` ABI (= A3 `searchFramed`) so ADSQL replaces `CSQLiteShim`/libsqlite3 inside `libAppleDocsCore` |
| **F1** SQLite importer **[GATE]** | **✅ DONE** | `ADSQLImport` target: `Database.importSQLite(from:manifest:)` + `adsql import`; schema port + coercion + index/PK/UNIQUE port + manifest FTS5 rebuild + deep integrity; idempotent, deterministic |
| **F2** FTS byte-parity | **✅ LANDED** | bm25f score parity **+ ranked-order parity** (ties → ascending rowid via the bounded-top-N upper-bound fix) proven through the importer vs SQLite FTS5 — `ImportedFTSParityTests.swift`, default + 5-weight |
| **F3** scalar + main-query surface | **✅ PROVEN** | full §2.2–2.4 main query byte-parity vs SQLite — `AppleDocsMainQueryTests`; `json_each` covered by the contracted `inJSONEach` shape (not RFC 0011's FROM-clause TVF) |
| **F4** covering/INCLUDE serving | **⏳ IN PROGRESS** | machinery exists; wiring `Planner` covering-detection (required-cols ⊆ index key ∪ includes) + executor activation + differential tests underway |
| **F5** streaming zero-copy scan | **PARTIAL** | `RowView` (~Escapable) + `RowCursor.forEachRow/forEachRecordSpan` exist package-internal; `Statement` only exposes `.all()` |
| **F6** build-time denormalization | **ABSENT** | inside F1 |
| **A1** compiled FTS-search primitive | **seams PRESENT** | `StatementCache` + per-`Statement` bound-plan cache + WAND; add typed `FTSSearchPlan` |
| **A2 / A4** caller row encoder / mmap→out | **bytes PRESENT** | `RecordCodec.withText/withBlob`, `RowSlot.withTextBytes/withBlobBytes` (in-place `RawSpan`); add projection API |
| **A3** one-call `searchFramed(into:)` | **ABSENT** (capstone) | composes A1+A2+F4+F5 |
| **A5** filters pushed into scan | **POST-FILTER today** | `Executor` residual WHERE after the FTS source yields |
| **A6** per-request snapshot + plan cache | **snapshot PRESENT** | pin one `ReadTxn`/request; cache `FTSSearchPlan` on the connection |
| **A7** vectorized top-k projection | **ABSENT** (optional) | free once A2 |

**Headline:** the hard engine pieces already exist — bm25f parity, block-max WAND, the zero-copy record
codec, the plan cache, wait-free MVCC snapshots. The program is mostly **importer + planner/executor
wiring + a thin accelerated API surface**, not new engine internals.

---

## 4. Part I — the swap gate (P0)

### F0 — Linux x64/arm64 **[THE #1 GATE]** · ✅ DONE
ADSQL's storage engine was Darwin-specific; the Glibc port now **builds + passes the full `swift test`
differential suite on x64 + arm64** (CI lane advisory only while it tracks the moving nightly tag). The
port surface that was addressed (behind a small platform shim):
- **IO** — `mmap`/`munmap`/`msync` are POSIX (portable); the Darwin-only calls to replace are
  `fcntl(F_BARRIERFSYNC)` (→ `fdatasync`/`sync_file_range`), `F_FULLFSYNC` (→ `fsync`), `F_NOCACHE`
  (→ `posix_fadvise(POSIX_FADV_DONTNEED)`), and APFS `clonefile` for O(1) snapshots (→ no CoW clone on
  ext4/xfs: `copy_file_range` or plain copy, losing the O(1) property — acceptable for an offline import).
- **Imports** — `import Darwin` → `#if canImport(Glibc) import Glibc`; `strerror_r` is XSI on Darwin vs
  GNU on glibc (different return type) — guard it.
- **Cross-process readers / writer lock** — confirm the shared-memory + `fcntl` locking path maps to
  Linux (`F_OFD_SETLK`).
- **Build/CI** — add a Linux lane (swiftly already in CI); verify `.strictMemorySafety()` + experimental
  Lifetimes compile on Linux Swift 6.3; confirm the `CSQLite` system target + ADJSONCore are Linux-clean.
- **Tests** — fence `clonefile`/`F_FULLFSYNC` cases behind `#if os(macOS)` with a Linux fallback arm.

**Sizing (portability audit — done).** No architectural rewrite: the engine is already Foundation-free
and uses portable **C11 atomics** (`ADCAtomics`) for cross-process sync (the hardest part), and there are
**zero `#if os` conditionals today** — the Darwin surface is ~11 bare `import Darwin` sites + two IO files
(`FileChannel.swift`, `MMap.swift`). Per subsystem:
- **IO / mmap — S.** `mmap`/`madvise`/`pread`/`pwrite`/`pwritev`/`O_*` map 1:1 to Glibc (import swap + flag aliases).
- **Durability + snapshots — M (largest).** `F_PREALLOCATE`+`fstore_t` → `posix_fallocate`; `clonefile`
  has **no Linux CoW** → fall back to `copy_file_range`/plain copy (snapshots lose O(1), fine for an
  offline import); the barrier/full-fsync forks are trivial (`fsync` is already the local fallback).
- **Cross-process — S.** C11 atomics + `fcntl`/`flock`/`kill` already portable; but `strerror_r`
  (`Errors.swift:54`) is the **XSI variant and is silently wrong under glibc's GNU variant — a must-fix**,
  and `pthread_attr_set_qos_class_np` + `clock_gettime_nsec_np` need an `#if`-out (no correctness impact).
- **Build / CI — M.** `#if canImport(Glibc)` scaffolding across ~11 files, de-risk `.strictMemorySafety()`
  + experimental `Lifetimes` on Linux Swift, wire `libsqlite3-dev` (only `ADSQLImport`/bench/tests need it,
  not the core engine), add a Linux CI matrix lane.
- **Tests — S/M.** Mostly portable (Foundation + POSIX); fence `F_FULLFSYNC`/`_np`-timing cases.

### INT — `Storage` backend swap **[GATE]** · ABSENT
**ADSQL does not invent a new C ABI** — apple-docs already owns the `@_cdecl` wrappers
(`ad_storage_open`/`_close`/`_search_pages`, each `(UnsafePointer<UInt8>?, Int) -> ResultBuffer`, with
`ad_abi_version() == 1`; `swift/Sources/ADCore/StorageExports.swift`), the request/response byte format
(§2.5, verbatim), and `ResultBuffer`/`RequestReader`. Those wrappers delegate to a Swift `Storage` type —
`Storage.open(path:) -> handle`, `Storage.close(handle)`, `Storage.searchPages(handle:, SearchPagesParams)
-> [UInt8]?` — which **today wraps the dlopen'd libsqlite3 via `CSQLiteShim`**.

**ADSQL's INT job: become that `Storage` backend.** apple-docs' `swift/` package takes ADSQL as a
**SwiftPM dependency** (⇒ requires **F0 Linux**), and `Storage.searchPages` runs the §2.2 main query
against the **F1-imported** ADSQL corpus and frames the §2.5 cells — i.e. A3 `searchFramed` emitting
apple-docs' wire format. The escape hatch already exists: if the backend is unavailable the wrapper
returns `.internalError` and JS `bun:sqlite` serves, and the whole bridge is gated by apple-docs'
`APPLE_DOCS_NATIVE` switch — so the swap lands **dark, reversibly**. Runtime contract: **synchronous**
calls, prepared-plan reuse, and a read-only multi-reader pool (one ADSQL `ReadTxn` per pool worker — a
natural fit for wait-free MVCC; the `bun:sqlite` writer is untouched).

**A macOS prototype is feasible first** — wire ADSQL as the `Storage` backend on macOS and prove
byte-identical `searchPages` output vs `bun:sqlite` via apple-docs' `test/unit/native/storage-search-pages.test.js`,
*before* Linux. Correctness-first: the prototype may use the existing `.all()` path + manual framing;
F5/A2–A4 then optimize the framing without changing the bytes.

### F1 — SQLite-file importer **[THE GATE]** · ✅ DONE
A library API + `adsql import` CLI: read a SQLite `.db` (via the existing `CSQLite` dep) → write an
ADSQL database.
- **Schema port** with **loose→strict coercion** (SQLite dynamic typing → ADSQL `Value`): the tables +
  columns in §2.1, preserving **`id` rowids** (the FTS↔documents join key). Reuse `SQLFunctions.cast`
  (`Functions.swift`) as the coercion primitive.
- **FTS5 reconstruction via an explicit import manifest** (SQLite's FTS5 config isn't fully
  introspectable): per FTS table — columns, `tokenize` (porter/unicode61/trigram), the external-content
  link (`documents_trigram` → `documents.title` by rowid), and the bm25 default weights. **Rebuild**
  ADSQL FTS indexes from the source rows (not a binary copy).
- **Idempotent, resumable, checksummed**, emits an integrity report; **deterministic** — two imports of
  the same `.db` produce byte-identical ADSQL files.
- Where: new `Sources/ADSQLKernel/Importer.swift`, `Database.importSQLite(from:manifest:)`, an
  `adsql import` subcommand.

### F6 — build-time denormalization (lives inside F1) · ABSENT
At import, precompute into covering columns: (a) **tier inputs** — `title_lc` (lowercased title) + an
exact/prefix-ready key, so the tier is pure comparison; (b) the **roots** `display_name`/`slug` folded
into each document (drops `LEFT JOIN roots`); (c) numeric platform values (already `min_*_num`). The
read query then collapses to **FTS-rank + equality/range only** — no `documents`/`roots` JOIN, no
`LOWER`/`LIKE`/`INSTR`/`json_extract`/`CASE` at query time. The single biggest simplifier; powers F4/A1.

### F2 — FTS ranking **byte-parity** with SQLite FTS5 · PRESENT (gate pending)
The engine is parity-*capable* — bm25f with per-column weights (k1=1.2, b=0.75), porter+unicode61 +
trigram, and **deterministic tie-breaking** (`WANDTopK` stable by score then docid). What's missing is
the **proof against the apple-docs corpus**: extend the differential harness (`FTSParityTests.swift`) to
run the query corpus against both engines and diff row order (gate:
`test/unit/native/storage-search-pages.test.js` byte-exact).

### F3 — confirm (not add) the scalar surface · PRESENT
Verify byte-parity of `COLLATE NOCASE` equality (title-exact tier) and `LIKE LOWER($raw)||'%'`. No new
functions expected; if F6 lands, the read query uses none of these at runtime anyway.

### F4 — covering / `INCLUDE`-index serving **[the memory-bandwidth fix]** · PARTIAL
Answer the ranked top-k **index-only**: the §2.3 projection + §2.4 filter columns stored as covering
columns on the FTS index, so `MATCH … ORDER BY rank LIMIT k` is served straight off the index cursor
with **no descent into the 4 GB `documents` table** — the working set shrinks from 4 GB to the covering
postings + stored columns. The data structures exist (`IndexDefinition.includes`,
`RowView.coveringIncludes`); the work is wiring `Planner.chooseIndex` to detect "projection ⊆ columns ∪
includes" and the executor to pass `coveringIncludes` to `RowCursor` instead of reading the base table.

### F5 — streaming, zero-copy scan API · PARTIAL
Replace `.all() → [SQLRow]` materialization with a **scan callback** (or `~Escapable` cursor) yielding
one `RowView` at a time with `RawSpan` column access, bounded by `LIMIT k`, early-terminating after k.
The machinery exists (`RowView`, `RowCursor.forEachRow`); the work is exposing it on the **public**
`Statement` API.

---

## 5. Part II — boundary collapse (P1/P2)

Today one `/search` "hop" is: build params → bind prepared SQL → parse/plan/exec → box each column into
`Value` → materialize `[SQLRow]` → re-encode to wire bytes → return `[UInt8]` → FFI. Every arrow is a
copy/allocation. These collapse the middle to a single zero-copy call.

- **A1 — compiled FTS-search primitive (P1).** A typed, prepared `FTSSearchPlan(table, queryParam,
  bm25Weights, filters:[TypedPredicate], projection:[ColumnId], tier:TierSpec, limit)` — **compiled once
  and cached**, executed per request with only bound params. Skips lexer→parser→binder→planner (pure
  overhead for a 20-row top-k run thousands of times/sec). Lowers to the same kernel scan as the SQL path.
- **A2 — caller-driven row encoder (P1).** The scan emits through a caller `RowEncoder` that receives
  **`RawSpan` views of each projected column** and writes the `[u8 tag][payload]` cells (§2.5) directly
  into the output buffer — no `Value` boxing, no `[SQLRow]`. ADSQL already owns the record bytes
  (`RecordCodec`); expose "project these `ColumnId`s into this `MutableRawSpan` in this order."
- **A3 — one-call `searchFramed(reader, plan, params, into:&out) -> Int` (P1, capstone).** MATCH → WAND
  rank → filter → project → frame in a single call, writing the apple-docs wire format directly.
  apple-docs' `ad_storage_search_pages` becomes a thin shim (decode → call → return). **Lowest hopping
  cost.**
- **A4 — mmap→response single-copy for TEXT/BLOB (P1).** The wide TEXT columns (`abstract`,
  `declaration`, `source_metadata`, `platforms_json`; ~13–31 KB) are the per-row cost. Copy them
  **once**, directly from the mmap'd page (`RawSpan`) into `out`, with **no `String` materialization and
  no UTF-8 re-validation**. The largest single saving.
- **A5 — filters pushed into the scan (P2).** Evaluate the typed predicates **during** the block-max
  WAND scan to skip non-matching docs before scoring/projection, rather than as a post-filter `WHERE`
  (the current behaviour). Fewer postings touched, fewer rows projected.
- **A6 — per-request pinned read snapshot + plan cache (P2).** One wait-free MVCC `ReadTxn` pinned for
  the request; the compiled `FTSSearchPlan` cached on the connection by `(table, projection,
  filter-shape)`. Pairs with apple-docs' `ConnectionPool` (one ADSQL reader per pool slot).
- **A7 — vectorized top-k projection (P2, optional).** Project the k result rows in a tight loop over
  contiguous covering entries — cache-friendly, SIMD-able memcpy. Free once A2 exists.

---

## 6. Phasing

The critical path splits in two: the **adoption gate** (apple-docs can run on ADSQL *at all*) comes
first; the **perf features** then make it *beat* SQLite — the reason for the swap (the ~32 req/s ceiling).

- **P0a — adoption gate (all must hold before a swap):** ✅ **F1** importer · ✅ **F2** FTS byte-parity ·
  ✅ **main-query surface parity** (`AppleDocsMainQueryTests` — §2.2–2.4 byte-identical; `json_each` via the
  contracted `inJSONEach`, not RFC 0011) · ✅ **F0** Linux x64/arm64 (builds + full suite green on
  x64+arm64) · **INT** the `ad_storage_*` engine swap — **the last remaining gate item**. Until these
  hold, apple-docs cannot run on ADSQL.
- **P0b — read-path perf (why the swap is worth it):** **F6** build-time denormalization (inside F1) →
  **F4** covering serve *(in progress)* → **F5** streaming zero-copy scan.
- **P1 — boundary collapse:** **A1** search primitive → **A2** caller encoder → **A3** one-call framed
  (= the `INT` ABI body) → **A4** mmap→out single-copy.
- **P2 — polish:** **A5** pushed filters, **A6** snapshot/plan-cache wiring, **A7** vectorized.

---

## 7. Parity & verification

- **Intrinsic gate:** the ADSQL reader must return **byte-identical rows + ordering** to the SQLite
  reader. Gate = apple-docs `bun test test/unit/native/storage-search-pages.test.js` +
  `test/unit/native/web-routes-parity.test.js`.
- **ADSQL side:** `swift test` + `swift test --sanitize=thread` (subset) + `swift run -c release
  ADSQLBench` green on **arm64 and x86_64**; the new corpus differential FTS-parity harness green.
- **apple-docs side:** `bun test/bench/load.mjs` — `/search` throughput **scales with cores** (vs the
  32 req/s ceiling), p99 drops under concurrency.

**Net target:** `ad_storage_search_pages` reduced to `decode → searchFramed(into:) → return`, served
index-only off a covering FTS index under wait-free MVCC, with the only copies being mmap→FFI-buffer.
`/search` scales linearly with cores instead of flat-lining at ~32 req/s.

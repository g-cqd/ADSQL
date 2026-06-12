# ADSQL

A from-scratch, pure-Swift embedded database engine for macOS. Copy-on-write
B+tree over mmap, single-writer / wait-free-reader MVCC, crash-safe by
construction (committed pages are immutable; recovery is picking the newest
checksum-valid meta page).

Status: storage kernel (KV layer) under active development. Relational layer,
SQL front end, and first-class FTS/vector indexes are planned on top of the
same on-disk format.

- Platform: macOS 26+, Apple Silicon first (16 KiB native pages)
- Toolchain: pinned via `.swift-version`; Swift 6 language mode, strict concurrency
- Dependencies: none
- Durability profiles: `.barrier` (F_BARRIERFSYNC, default), `.full`
  (F_FULLFSYNC), `.none` (bench)

## Layout

- `Sources/ADSQLKernel` — VFS, pager, COW B+tree, MVCC transactions, free-list,
  commit protocol, recovery, integrity.
- `Sources/ADSQL` — public façade.
- `Tests/ADSQLTestSupport` — reference model store, seeded op generator,
  simulated disk for crash injection.

## Benchmarks

`swift run -c release ADSQLBench` compares against system SQLite (WAL,
apple-docs production pragmas) on a document_chunks-shaped dataset
(200k–858k rows, ~580 B values). On an M-series 10-core machine, 200k rows:

| Scenario | ADSQL | SQLite (WAL) | Δ |
|---|---|---|---|
| cold open → first get (p50) | 31 µs | 399 µs | **13×** |
| point get p50 (uniform) | 0.9 µs | 3.6 µs | **4×** |
| full scan | 4.3 GB/s | 4.2 GB/s | ≈ |
| 16 readers during write churn | 1.04 M reads/s, p99 243 µs | 349 k reads/s, p99 466 µs | **3× / ½ tail** |
| batch upsert ×64 (ordered durability)¹ | 96–110 k rows/s | 108 k rows/s | ≈ |
| batch upsert ×64 (no sync) | 374 k rows/s | 142 k rows/s | **2.6×** |
| bulk load 200k rows | 488 k rows/s | 171 k rows/s | **2.9×** |

¹ ADSQL `.barrier` (one F_BARRIERFSYNC per commit, crash-consistent by
construction) vs SQLite `synchronous=FULL` (fsync per WAL commit) — the
closest durability semantics on macOS.

## Develop

```sh
swift build
swift test
swift test --sanitize=thread   # concurrency lane
```

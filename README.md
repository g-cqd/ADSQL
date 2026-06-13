# ADSQL

A from-scratch, pure-Swift embedded database engine for macOS. Copy-on-write
B+tree over mmap, single-writer / wait-free-reader MVCC, crash-safe by
construction (committed pages are immutable; recovery is picking the newest
checksum-valid meta page).

Status: storage kernel, relational layer, and the SQL front end (M4/M4.5)
complete; a scan-engine performance pass (M4.6) is active, with first-class
FTS/vector indexes (M5) next, on the same on-disk format. See
[`ROADMAP.md`](ROADMAP.md) for the full milestone suite, performance headroom,
and the deferred-SQL registry, and [`docs/rfcs/`](docs/rfcs/) for design
records.

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

Relational layer (M3), documents-shaped table with 5 secondary indexes,
200k rows (`ADSQLBench table`):

| Scenario | ADSQL | SQLite | Δ |
|---|---|---|---|
| rowid point get (p50 / p99.9) | 1.0 µs / 24 µs | 2.4 µs / 170 µs | **2.4× / 7×** |
| unique-key probe (p50) | 1.1 µs | 1.3 µs | ≈+ |
| batch insert ×512 (5-index maintenance) | 101 k rows/s | 128 k rows/s | 0.79× ² |
| index range scan (33k rows) | 1.1 M rows/s | 2.8 M rows/s | 0.39× ² |

² Known headroom, addressed by the M4 executor: per-row dictionary
assembly on insert, eager full-row materialization on scans.

## Develop

```sh
swift build
swift test
swift test --sanitize=thread   # concurrency lane
```

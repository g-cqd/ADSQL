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

## Develop

```sh
swift build
swift test
swift test --sanitize=thread   # concurrency lane
```

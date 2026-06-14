# ``ADSQL``

A pure-Swift, SQLite-compatible embedded SQL database for Swift 6 — a crash-safe
storage engine with a SQLite-grammar query layer and FTS5-style full-text search, in
one zero-dependency package.

## Overview

ADSQL stores data in a single file as a **copy-on-write B+tree over an `mmap`'d page
heap** (16 KiB pages, XXH64-checksummed). Concurrency is **single-writer / wait-free
reader MVCC**: readers observe an immutable committed generation and never block the
writer, while writes are **group-committed** for durability without per-write `fsync`
cost. The on-disk format is crash-safe by construction — a partially written
generation is never observable.

```swift
import ADSQL

let db = try Database.open(at: "/tmp/app.adsql")
defer { db.close() }

try db.prepare("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)").run()
try db.prepare("INSERT INTO users(name) VALUES (?)").run(.text("Ada"))

let rows = try db.prepare("SELECT id, name FROM users ORDER BY id").all()
for row in rows {
    print(row[0], row[1])   // .integer(1) .text("Ada")
}
```

Writes run through typed-throws transactions and are batched into durable group
commits:

```swift
try await db.write { (txn) throws(DBError) in
    try txn.insert(into: "users", ["name": .text("Grace")])
}
```

### Design highlights

- **SQLite-compatible SQL** — a hand-written lexer/parser/planner covering the common
  SELECT/INSERT/UPDATE/DELETE surface, joins (nested-loop, hash, and merge), subqueries,
  aggregates, compound queries, upserts, `RETURNING`, and JSON functions, validated by a
  differential suite that runs every query against SQLite.
- **Full-text search** — an FTS5-compatible virtual table with `porter` / `unicode61` /
  `trigram` tokenizers and BM25 ranking accelerated by a WAND top-k scorer.
- **Strict memory safety** — the engine compiles under SE-0458 `.strictMemorySafety()`;
  every `Unsafe*`/`RawSpan` page view is explicitly scoped and lifetime-checked.
- **Zero dependencies** — only the Swift standard library, `Synchronization`, and Darwin.

## Topics

### Opening a database

- ``Database``
- ``DatabaseOptions``
- ``DurabilityProfile``

### Statements and results

- ``Statement``
- ``Row``
- ``RowView``
- ``Value``
- ``RunResult``

### Transactions

- ``ReadTxn``
- ``WriteTxn``

### Defining schema

- ``TableDefinition``
- ``ColumnDefinition``
- ``ColumnType``
- ``PrimaryKey``
- ``IndexDefinition``
- ``ForeignKey``

### Full-text search

- ``FTSDefinition``
- ``PorterTokenizer``
- ``Unicode61Tokenizer``
- ``TrigramTokenizer``

### Tuning execution

- ``ExecutionOptions``
- ``ExecutionOptions/Evaluator``

### Errors and integrity

- ``DBError``
- ``IntegrityReport``

### Version

- ``ADSQLInfo``

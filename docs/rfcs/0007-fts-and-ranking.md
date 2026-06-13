# RFC 0007 — Full-Text Search & Ranking (M5)

Status: proposed. The design of record for ADSQL's full-text search milestone (M5):
a from-scratch, **state-of-the-art** inverted index + ranking, the `CREATE VIRTUAL
TABLE … USING fts5(…)` / `MATCH` / `bm25()` SQL surface, and a complete index-sync
story (the FTS write API + general `CREATE TRIGGER`). M5 is the **apple-docs
migration blocker** — apple-docs search is 100% FTS5. Companion to the storage
kernel (M0–M2), the SQL engine (RFC 0001), and the perf program (RFC 0004/Review
0002). Execution is phased (F0–F6); each phase is its own slice behind tests + a
moving `ADSQLBench` number.

## Goals & stance

- **Best-in-class performance.** Leverage the state of the art from the leading
  engines (Lucene, Tantivy, PISA) and **beat SQLite FTS5** on MATCH latency and
  ranked top-k — block-max WAND over block-compressed postings vs FTS5's doclist
  scan. Every perf claim ships behind an `ADSQLBench fts` number (RFC 0002 lesson).
- **Correct, well-ranked results.** bm25 + **bm25f** (per-field weights — what
  apple-docs's `bm25(t, w0..wN)` is). The bar is *not* byte-for-byte SQLite parity;
  it is SOTA quality, with **boolean MATCH membership matching SQLite** (a
  well-specified property → kept as a differential gate) and bm25f ranking validated
  by ordering/monotonicity + relevance tests.
- **Complete sync.** The FTS write API *and* general `CREATE TRIGGER`, so apple-docs's
  trigger DDL ports verbatim.
- **No architectural compromise.** Same COW/mmap/single-writer/wait-free-reader
  engine; zero external deps; no Foundation in the kernel; `-strict-memory-safety`;
  typed `throws(DBError)`; commit-per-slice; TSan green.

## Non-goals (M5)

Byte-identical SQLite tokenization/bm25; FTS5 auxiliary functions beyond what
apple-docs uses (`highlight`/`snippet` only if needed); custom/external tokenizer
plugins; `fts5vocab`; NEAR/`+`-column-restrict beyond apple-docs's grammar; vector
search (app-side BLOB math, orthogonal). Cross-platform (Linux) tracked separately.

## Consumer requirements (apple-docs, exact)

| FTS table | columns | tokenize | content mode | ranking |
|---|---|---|---|---|
| `documents_fts` | title, abstract, declaration, headings, key | `porter unicode61` | self-contained | `bm25(documents_fts,10,5,3,2,1)` (bm25f) |
| `documents_trigram` | title | `trigram case_sensitive 0` | external (`content='documents', content_rowid='id'`) | `bm25(documents_trigram)` |
| `documents_body_fts` | body | `porter unicode61` | contentless (`content='', contentless_delete=1`) | `bm25(documents_body_fts,1)` |
| `sf_symbols_fts` | name, keywords, categories, aliases | `porter unicode61` | self-contained | `bm25(sf_symbols_fts)` |

Sync via `CREATE TRIGGER documents_ai/ad/au AFTER INSERT/DELETE/UPDATE`. MATCH
grammar used: prefix `*`, `AND`/`OR`/`NOT`, `"phrase"`, `(groups)`, quoted literals,
OR-of-trigrams. Queries `JOIN documents ON fts.rowid = documents.id`, filter on the
base table, `ORDER BY tier, rank` / `ORDER BY rank` / `ORDER BY bm25(...)`, `LIMIT`.
Corpus ≈ 350k docs.

## Architecture

### Inverted index (B+trees per FTS table)
Modeled like a table + its index trees (the multi-tree-per-object pattern the catalog
already supports); a catalog **FTS record** holds the config + tree roots.

- **Term dictionary** (B+tree): order-preserving `term → {termId, df, postings ref}`.
  Sorted keys give **prefix queries** for free (`foo*` ⇒ key range `[foo, prefixSuccessor(foo))`,
  reusing `KeyCodec.prefixSuccessor`) and dictionary merges; trigram tokens are 3-byte
  terms in the same structure.
- **Postings** (block-compressed): per term, docid-ascending **blocks** (~128 postings)
  — delta + varint to start (`ByteCodec`), upgradeable to **PForDelta / SIMD-BP128**
  (Lemire & Boytsov) and **roaring** for dense lists. Each block stores a **block-max
  impact** (max bm25f contribution in the block) to drive **Block-Max WAND / MaxScore**
  (Ding & Suel 2011; Turtle & Flood). Positions live in a parallel stream for phrase
  queries; `detail=full|column|none` (à la FTS5) trades phrase support for size.
- **Doc/field stats** (B+tree): per-doc per-field length + global Σ for bm25f length
  normalization. Large postings spill through `Overflow`.
- **Segments + COW:** buffer writes, flush immutable segments, background-merge
  (Lucene/Tantivy LSM-of-segments). Fits COW naturally — a segment is a new tree; old
  readers keep old roots; merges free old segments via the reader reclamation horizon.

### Ranking — bm25 / bm25f
bm25 (Robertson & Spärck-Jones; k1, b) and **bm25f** (Robertson, Zaragoza, Taylor,
CIKM 2004 — per-field weight + per-field length norm), which is precisely apple-docs's
weighted `bm25(table, w…)`. SQLite-compatible sign (negative scores, `ORDER BY rank`
ascending = best first) so `ORDER BY rank`/`bm25(...)` is drop-in. Top-k computed by
block-max WAND over per-block max impacts (skips blocks that can't enter the heap).

### Query evaluation
A MATCH query-string mini-parser → an operator tree (term, prefix, phrase, AND, OR,
NOT, group, `col:`). Boolean eval over postings: AND = galloping intersection, OR =
heap/union, NOT = difference, phrase = position check, prefix = dictionary-range union.
Ranked retrieval (`ORDER BY rank LIMIT k`) uses block-max WAND for a true top-k (no
full sort) — reusing the executor's bounded top-N heap.

### Tokenizers (own, SOTA-quality)
A `Tokenizer` protocol; `unicode61` (Unicode word-break + case-fold + optional diacritic
removal via compact generated tables), `porter` (Porter2/Snowball-class stemmer over
unicode61 tokens), `trigram` (sliding 3-gram, case-fold). SIMD-friendly UTF-8 scanning
on the hot path. Tokens carry (term bytes, source byte span for highlight/snippet,
position).

### SQL integration
- **`CREATE VIRTUAL TABLE … USING fts5(columns, tokenize=, content=, content_rowid=,
  prefix=, detail=, columnsize=)`** → new statement AST + catalog FTS record.
- **`MATCH`** → a binary operator parsed at `equality()` precedence (the `LIKE`
  precedent); a new `AccessPlan.fts` + `RowSource.fts` yields matching rowids (ranked
  or rowid-order), joined to the base table on rowid (the secondary-index-access
  precedent). The `.inJSONEach` contracted shape is the closest existing "special
  predicate/source" analog.
- **`bm25()` / `rank`** → a *context-aware* ranking value the FTS source produces per
  row (a pure scalar can't see the match/stats); surfaced as the `rank` pseudo-column,
  usable in `ORDER BY`. `highlight()`/`snippet()` only if apple-docs needs them.
- **Content modes:** self-contained (store columns), external (`content='t'` — read
  columns/length from the base table), contentless (`content=''`, `contentless_delete`).

### Sync — complete
1. **FTS write API:** `INSERT INTO fts(rowid, cols…)`, `DELETE FROM fts WHERE rowid=…`,
   the `'delete'` idiom — tokenize + update postings/stats.
2. **General `CREATE TRIGGER`** (`AFTER INSERT/UPDATE/DELETE`, `NEW`/`OLD` row refs,
   trigger-body INSERT/DELETE) fired in the DML path — apple-docs's triggers port
   verbatim.
3. external-content auto-read for ranking/columns.

## On-disk format
New trees (dictionary/postings/stats) per FTS record, rooted in the catalog under the
reserved `0x00` prefix alongside table/index roots; keys via `KeyCodec`, values via
`RecordCodec`/block codec, big values via `Overflow`. This is a **format addition** —
bump `Format.formatVersion` (gate older readers) and ship with crash-injection coverage
(M6 harness). Covering-index/zone-map format additions (RFC 0004 P1) can ride the same
version bump.

## References (SOTA)
WAND (Broder et al. 2003); **Block-Max WAND** (Ding & Suel, SIGIR 2011); MaxScore
(Turtle & Flood 1995); PForDelta / SIMD-BP128 (Lemire & Boytsov, SPE 2015); Roaring
(Lemire et al. 2016); bm25 (Robertson & Spärck-Jones 1976/1994); **bm25f** (Robertson,
Zaragoza, Taylor, CIKM 2004); Lucene / Tantivy segment architecture; PISA (Mallia et
al. 2019); SQLite FTS5 (the baseline to beat).

## Phases
- **F0** — `CREATE VIRTUAL TABLE USING fts5(…)` parse + AST; catalog FTS record
  (dictionary/postings/stats trees + config) + DROP + schema cache; storage key layout.
- **F1** — tokenizers (`unicode61`, `porter`, `trigram`) + protocol + tests.
- **F2** — FTS write API; tokenize → block postings (+ block-max) + doc/field stats;
  content modes; segment flush + merge.
- **F3** — MATCH operator + query grammar; boolean/phrase/prefix → rowids;
  `AccessPlan.fts`/`RowSource.fts`; **membership differential-vs-SQLite**.
- **F4** — bm25/bm25f + per-column weights; block-max WAND top-k; `bm25()`/`rank` +
  `ORDER BY rank LIMIT k` true top-k.
- **F5** — general `CREATE TRIGGER` fired in DML.
- **F6** — the 4 apple-docs tables/modes verbatim; `highlight`/`snippet` if needed;
  `ADSQLBench fts` + SQLite-FTS5 parity harness; perf-tune to beat SQLite FTS5.

## Verification
- **Correctness:** boolean MATCH membership differential-vs-CSQLite FTS5 on a shared
  fixture (AND/OR/NOT/phrase/prefix); bm25f ordering/monotonicity + property tests;
  tokenizer unit tests; crash-injection on the FTS trees; TSan; strict-MS 0 warnings.
- **Performance (the mandate):** `ADSQLBench fts` vs CSQLite FTS5 on an apple-docs-shaped
  corpus (≥100k docs) — index-build rows/s, MATCH p50, `ORDER BY bm25 LIMIT 20` top-k
  p50. Target: beat SQLite FTS5; report against the Tantivy/PISA-class aspiration.
- **apple-docs:** the four tables' exact DDL + `bm25(...)` weights + trigger DDL execute;
  a parity harness shows equivalent top results vs the current SQLite output.

## Risks
Tokenizer/bm25 divergence from SQLite (mitigated: boolean membership is the gate,
ranking validated separately); format-version migration (gated, crash-tested); the
scope is large (phased, re-confirmed at each boundary); `CREATE TRIGGER` is a sizable
sub-feature (its own slice, F5).

# RFC 0006 — Swift Metaprogramming & DSL Adoption (type-safe query DSL, macros, language sugar)

Status: proposed. A focused pass over **Swift language features ADSQL does not yet leverage** —
result builders, attached/freestanding macros, operator overloading + custom operators,
`@dynamicMemberLookup`, `@dynamicCallable`, `callAsFunction`, and custom property wrappers —
weighed for two payoffs: a **type-safe, injection-safe public query DSL** and **internal
boilerplate/codegen** wins. Like RFC 0005 this is an *adoption + deliberate-decline* report;
nothing here changes code. Researched by source-tracing the AST/codec/row layers and against a
reference result-builder DSL (`g-cqd/URLBuilder`) and Apple's DSL family (SwiftUI `ViewBuilder`,
RegexBuilder).

The headline is **not** "add macros for speed." It is a correction of that premise (§Framings 1)
plus one architecture call: RFC 0005 assessed Point-Free's `swift-structured-queries` as "a SQL
string builder that would sit *above* ADSQL, not inside it" and declined it. RFC 0006 proposes
the **native, in-tree equivalent** that sits *inside* the `ADSQL` umbrella, **builds the public
AST directly** (skips lex+parse), and needs **no external dependency** for its core tier
(§Challenges 1).

## Three framings that drive every verdict

1. **Macros are compile-time codegen, not a runtime-speed tool.** They emit ordinary Swift; a
   generated accessor is exactly as fast as the hand-written one — wins are line-count, safety,
   maintainability. The *only* runtime win on offer is **structural**: a query DSL feeds the AST
   straight to `Binder.bindQuery`/`Writer.execute`, **skipping the lexer/parser** (and the
   parse-cache string hashing). `@dynamicMemberLookup`, `callAsFunction`, operators, and
   `@dynamicCallable` are **zero-cost sugar**. **Property wrappers are the exception** — stored
   state + synthesized accessors, a real cost (§T8).
2. **Strict memory safety + `~Escapable` constrain the sugar.** `@dynamicMemberLookup` needs a
   *non-throwing, non-mutating* `subscript(dynamicMember:)`. The hot row reader `RowView`
   (`Rows.swift:40`) is `~Copyable, ~Escapable` and its column access **throws** (the lifetime
   enforcement is **Review 0001 F1**) — so dynamic member lookup is a structural non-fit there
   (§T5).
3. **The expression DSL fights `Equatable`.** Overloading `==`/`<` to *build predicates* collides
   with `Equatable`/`Comparable` returning `Bool`. Resolving this cleanly is the single most
   important DSL decision and the reason operator-heavy builders stress the type-checker (§T2).

## Already leveraged — credit (clean slate, with usable seams)

These features are **not** used anywhere today (`grep`: zero `@dynamicMemberLookup`,
`@dynamicCallable`, `@propertyWrapper`, `callAsFunction`, custom `operator` decls). What already
exists and should be *reused, not reinvented*:

| Existing asset | Use for the DSL | Site |
|---|---|---|
| Public AST value types (`SQLExpr`, `SQLSelect`, `SQLStatementAST`) | the lowering target | `SQL/AST.swift` |
| `Statement` stores a public AST; binder/executor consume it directly | feed built AST, skip parser | `SQL/Statement.swift:80-156` |
| `ParsedStatement{ast,isReadOnly}` (internal); `SQLStatementAST.isReadOnly` (public) | the `prepare(ast:)` seam (~5 lines) | `SQL/Statement.swift:316`, `AST.swift:186` |
| `SQLRow`/`Row` name subscripts; `TableDefinition`/`ColumnDefinition` | dynamic-member rows; `@Table` schema | `Statement.swift:50`, `Rows.swift:2`, `Definitions.swift:7` |

## Master decision table

| # | Feature | Where | Verdict | Why (one line) |
|---|---|---|---|---|
| T1 | **Result builders** | query/DDL DSL; test fixtures | ★ **ADOPT** | Declarative tree of value types = textbook fit; the headline. |
| T2 | **Operator overloading** | expression DSL (`Col("a") > 3`) | ✓ **ADOPT (scoped)** | Core ergonomics; builder type must stay non-`Equatable`. |
| T2b | **Custom operator *symbols*** | LIKE/assign/BETWEEN | ✗ **DECLINE** | Named methods (`.like`, `.in`, `.between`) beat novel symbols. |
| T3 | **Freestanding `#SQL`** | expression-context queries | ✓ **ADOPT** | Thin `ExpressionMacro` over the builder (à la `#URL`). |
| T3b | **Freestanding `#predicate`** | closure → predicate | ◻ **DEFER** | SwiftData-style; large macro; operators cover ~90%. |
| T4 | **`@Table`** (member+extension) | typed schema + columns | ✓ **ADOPT** | One schema truth → DSL + dynamic lookup + typed predicates. |
| T4b | **`@FixedLayout`** (member) | `Meta`, `PageHeader` | ✓ **ADOPT (modest)** | Auto-offsets; generates declarations only a macro can. |
| T5 | **`@dynamicMemberLookup`** | eager `SQLRow`/`Row`, JSON | ✓ **ADOPT** | `row.score`, `json.user.name`; **NOT** on throwing `RowView`. |
| T6 | **`@dynamicCallable`** | `db("…")` bridge | ✗ **DECLINE** | Stringly-typed; defeats the type-safety goal. |
| T7 | **`callAsFunction`** | prepared `Query<Output>` | ◻ **ADOPT 1** | `query(min:3)` reads well; don't make everything callable. |
| T8 | **Custom property wrappers** | schema markers | ✗ **DECLINE** | Storage/cost; peer macros (`@Attribute` model) are the tool. |
| T9 | **Plain Swift** (no feature) | `SQLExpr.mapChildren`; `Value` tag codec | ✓ **ADOPT** | Captures the structural-walk win with no macro/dep. |

Legend: ★ headline · ✓ adopt · ◻ partial/defer · ✗ decline.

## Catalog

### T1 · Result builders — the SQL query & DDL DSL  *(fit: yes; ROI: high; effort: high; risk: med — type-checker)*
The AST is clean public value types → result builders are the idiomatic constructor (SwiftUI,
RegexBuilder, URLBuilder). Wins: **compile-time structure**, **injection-safety** (user values
become `.literal(Value)`/bound params — never SQL text, so they cannot be parsed as syntax), and
the **structural runtime win** (skip lex+parse). Seam:
```swift
extension Database {                                            // ADSQLKernel/SQL/Statement.swift
  public func prepare(_ statement: SQLStatementAST) -> Statement {
    Statement(database: self, sql: "<built>",
              parsed: ParsedStatement(ast: statement, isReadOnly: statement.isReadOnly)) } }
```
**Surface** (SwiftUI `some` component protocol + URLBuilder-style lowering of capitalized clause
types into the AST):
```swift
let stmt: SQLStatementAST = SQL {
  Select { Col("id"); Col("score"); Count(star: true).as("n") }
  From("docs"); Join("authors", on: Col("docs","author") == Col("authors","id"))
  Where(Col("score") > Param("min"))
  GroupBy("author"); Having(Count(star: true) > 1)
  OrderBy("id", .descending); Limit(10)
}
try db.prepare(stmt).all(["min": .integer(3)])
// DDL/DML reuse the same column DSL:
SQL { CreateTable("docs") { Column("id", .integer, .primaryKey); Column("key", .text, .unique) } }
SQL { InsertInto("docs") { Columns("key","score"); Values(Param("k"), 9.5) }.onConflict(.ignore) }
SQL { Update("docs") { Set("score", to: Col("score") + 1) }.where(Col("id") == 5) }
SQL { DeleteFrom("docs").where(Col("score").isNull) }
```
- `SQL { … } -> SQLStatementAST` is pure/total (no DB, can't fail); a
  `db.prepare(@SQLStatementBuilder _:)` overload reads the builder directly. Bind-time errors
  (unknown table/column) still surface as `DBError` at execute — unchanged.
- **Design influences (not one template):** SwiftUI `ViewBuilder` (opaque `some SQLComponent`,
  `buildOptional/Either/Array` so `if`/`for` work in a block); RegexBuilder `RegexComponentBuilder`
  (typed-output threading — see tiers); URLBuilder (capitalized components lowered to AST, dual
  trapping/throwing entry, the `#…` macro); `PackageDescription`/SwiftPM (factory inits with defaults).
- **Type-safety tiers:** **T1 (always)** structural + injection-safe; **T2 (target — via `@Table`)**
  typed predicates, `Where(Doc.score > Param("min"))` checked against the struct; **T3 (deferred)**
  `Select<Output>` whose `Output` is the selected-column tuple, yielding `[(Int64, Double?)]`
  instead of `[SQLRow]` — revisit after T2, gated on type-checker cost.
- **Files (if built):** `Sources/ADSQL/Query/{Expression,Operators,Select,Writes,DDL,Builders,Prepare}.swift`.
- **No external dependency** (result builders are a language feature).

### T2 · Operators — overloading (the `Equatable` crux)  *(fit: yes; ROI: high; effort: med; risk: med)*
If the DSL wrapper overloads `==` to return a predicate it **must not** conform to `Equatable`
(whose `==` returns `Bool`). Keep the **AST `Equatable`** (tests/oracle); make the **DSL wrapper
a distinct, non-`Equatable`, non-`Comparable` type**:
```swift
public struct SQLExpression { let ast: SQLExpr }   // NOT Equatable/Comparable
public func == (l: SQLExpression, r: SQLExpression) -> SQLExpression { .init(ast: .binary(.eq, l.ast, r.ast)) }
extension SQLExpression: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral,
                         ExpressibleByFloatLiteral, ExpressibleByNilLiteral {}  // Col("x") == 3 / == nil
```
Overload the set that maps 1:1 to `SQLBinaryOp`/`SQLUnaryOp` (`AST.swift:31-51`):
`== != < <= > >= && || + - * / %`, prefix `-`/`!`. Because the wrapper isn't `Equatable`,
`Col("a") == 3` resolves unambiguously to the predicate-building `==`; literals lower to
`.literal(Value)` (injection-safe). Cost: wrapper verbosity + type-checker pressure (mitigated,
§Risks). This is exactly how query DSLs avoid the `Equatable` trap.

**T2b — custom operator *symbols*: decline; prefer named methods.**
- ✗ Symbolic LIKE (`~~` / `%`) → use `Col("k").like("a%")` (lowers to `.like`); reads as SQL with
  no precedence surprises.
- ✗ Assignment operator (`"score" <- expr`) → use the `Set("score", to: …)` method.
- ✗ Range / `IN` operators → use `Col("x").between(1, 10)` / `Col("x").in([1, 2])`.
- **General rule:** custom *symbols* cost discoverability and tooling; reserve operator
  *overloading* for the arithmetic/comparison/logical set users already expect, and expose
  LIKE/IN/BETWEEN/CAST/COLLATE as methods. Zero runtime cost either way.

### T3 · Freestanding `#SQL`  *(fit: yes; ROI: med; effort: low; risk: low — but pulls swift-syntax)*
A tiny `ExpressionMacro` expanding `#SQL { … }` → `SQL { … }` for property/`let` contexts
(verbatim of URLBuilder's `#URL`). The builder works **without** it — sugar only. **T3b
`#predicate { $0.score > 3 }`**: powerful (closure→AST, full key-path typing) but a large macro;
**defer**, operators cover most of it.

### T4 · `@Table` + `@FixedLayout`  *(fit: yes; ROI: high / modest; effort: med; risk: low)*
**`@Table`** (member + extension): on a plain struct, derive a typed **column namespace** +
`TableDefinition` (`Definitions.swift:50`) — *one schema truth* feeding the DDL builder, typed
predicates (T2), dynamic-member rows (T5), and fixtures. This is the **peak type-safety** play and
the reason to prefer macros over property wrappers for schema (§T8). Markers
(`@PrimaryKey`/`@Unique`/`@Indexed`) are **peer macros** (SwiftData's `@Attribute` model /
URLBuilder's `@Query`) read by `@Table` — **not** property wrappers.
```swift
@Table struct Doc { var id: Int64; var key: String; var score: Double? }
// generates: enum Columns { static let id = TypedColumn<Int64>("id"); … }; static var tableDefinition
SQL { Select { Doc.id; Doc.score }; From(Doc.self); Where(Doc.score > Param("min")) }
```
**`@FixedLayout`** (member): `Meta` (`MetaPage.swift:60-132`) and `PageHeader` (`Page.swift:15-95`)
hand-maintain an `Offset` enum + field-by-field `storeLE/loadLE`. Declare fields once → generate
**auto-computed offsets** + `@inline(__always)` LE accessors + encode/decode, preserving the
`unsafe`/`@safe` annotations strict memory safety requires.
```swift
@FixedLayout struct Meta { @LE var generation: UInt64; @LE var rootPage: UInt64 /* offsets computed */ }
```
**Exclude** NodeBuilder's leaf/branch cells — variable-length and flag-branched, not a clean fit
(`NodeBuilder.swift:69-130`); leave hand-written. Payoff ~35 lines + removes a hand-offset
corruption surface; **zero runtime change**; lower priority than the DSL, justified mainly because
swift-syntax is already in for T3/T4. Guardrail: byte-identical encode/decode test vs the hand
codec **before** swapping.

### T5 · `@dynamicMemberLookup`  *(fit: yes (eager rows + JSON) / no (RowView); ROI: med; effort: low; risk: none)*
- ✓ **Eager `SQLRow`/`Row`**: add a non-throwing string subscript → `row.score` (reuses the
  existing name subscript, `Statement.swift:59`). With `@Table` + `KeyPath`, a typed overload
  returns `T?`.
- ✓ **A public JSON value** wrapping `SQLJSON.Node` (`JSON.swift:6`) → `json.user.name` (build
  only if a public JSON accessor is wanted; internal today).
- ✗ **`RowView`** (hot lazy reader): dynamic member subscripts can't throw, but `RowView.value`
  **throws** and the type is `~Escapable` (Review 0001 F1) — a non-throwing subscript would
  swallow decode errors or trap on the hot path. Keep its explicit throwing API. *(This constraint
  is the kind of detail that makes or breaks the feature; calling it out is the point.)*
```swift
@dynamicMemberLookup public struct SQLRow {                  // reuses the existing name subscript
  public subscript(dynamicMember name: String) -> Value? { self[name] }
  // with @Table: subscript(dynamicMember: KeyPath<Doc.Columns, TypedColumn<T>>) -> T?  → typed access
}
```

### T7 · `callAsFunction`  *(fit: partial; ROI: low; effort: low; risk: none)*
Makes an instance callable (`value(args)` → `value.callAsFunction(args)`) — zero cost, fully typed
(unlike `@dynamicCallable`). One tasteful use: a prepared typed `Query<Output>` value —
`let q = db.query{…}; let rows = try q(min: 3)` ("run this query with these params"). Decline on
`Statement` (`stmt(.integer(3))` is ambiguous vs `all`/`get`/`run` — keep the explicit trio) and on
`Database` (`db("SELECT…")` re-introduces stringly-typed calls — see T6). Possibly a callable
scalar-function builder *if* user-defined SQL functions ever land; otherwise leave methods explicit.

### T9 · Plain Swift — the honest non-metaprogramming wins  *(fit: yes; ROI: med; effort: low; risk: low)*
- `SQLExpr.mapChildren(_:)`/`children` (~30 hand-written lines) to factor the *structural* AST
  walks (`rewriteAggregates`, `referencesOnlyBelow`, affinity/collation in `Plan.swift`/`Eval.swift`).
  **Do NOT touch the hot `evaluate` switch.** Perf-neutral, ~60-line cut; a macro to read 23 enum
  cases would cost more than it saves. (Orthogonal to RFC 0004 P0.2's DISTINCT win.)
- Optional shared `Value` tag-byte codec helper across RecordCodec/KeyCodec/Catalog.

## Challenges to prior findings

**1 · RFC 0005 — "a typed query DSL would sit *above* ADSQL (external `swift-structured-queries`)." → reframed, not contradicted.**
0005 correctly declined an *external* engine dependency on a SQL string-builder. RFC 0006 is the
**in-tree** counter-proposal: the DSL lives in the existing `ADSQL` umbrella module, lowers to the
**public AST** (not a string), executes via the new `prepare(ast:)` seam, and the **result-builder
+ operator core is dependency-free** — so it honors the zero-dep stance while delivering the
type-safety/injection-safety 0005's "above ADSQL" framing implied was out of reach internally.
Only the *macro tier* (T3/T4) takes swift-syntax (§Risks).

**2 · "Macros will improve runtime performance." → challenged, honest negative.**
Macros emit ordinary Swift; generated code is exactly as fast as hand-written. The genuine perf
wins remain algorithmic (RFC 0004) and allocation (Review 0002). The DSL's *only* runtime edge is
skipping lex+parse — small, and the existing parse-cache (`Statement.swift:323`) already softens
the string path. Adopt the DSL for **type-safety/injection-safety**, not speed.

**3 · "Annotate schema with property wrappers." → challenged (T8).**
A `@propertyWrapper` changes the field's stored type and adds a wrapper instance + accessors —
runtime/memory cost for a pure *marker*. SwiftData and URLBuilder use **macros** (`@Attribute`,
peer `@Query`) for exactly this. Use peer macros under `@Table`; wrappers earn their cost only for
runtime-wrapping behavior (lazy decode / change-tracking) — none compelling on ADSQL's immutable,
eagerly-decoded rows.

## Synergy — one schema truth, several payoffs

`@Table` is the keystone: its derived column namespace simultaneously powers the **DSL** (typed
clauses, T1/T4), **typed predicates** via operators (T2), **`@dynamicMemberLookup`** typed row
access (T5), **typed result tuples** (deferred T3), and **test fixtures** (reusing the DDL
builder). Adopting the rest *without* `@Table` still works with string columns — just untyped. So
the macro tier is an **upgrade path, not a prerequisite**: the P0 result-builder + operator core
stands alone.

## Prioritized recommendations (type-safety-first, zero-dep-aware)

- **P0 — dependency-free core.** `prepare(ast:)` seam (T1) + result-builder DSL (T1) + operators
  (T2). Proves the headline (type-safe, injection-safe queries) with **no external dependency**.
- **P1 — macro tier (swift-syntax).** `#SQL` (T3) + `@Table` (T4) for typed predicates; then
  `@dynamicMemberLookup` on `SQLRow` (T5), typed via `@Table`.
- **P2 — internal codegen.** `@FixedLayout` (T4b, rides swift-syntax already in); the plain-Swift
  `mapChildren` walk refactor (T9); test-fixture DSL (T1); callable `Query` (T7).
- **No-go / documented** — novel operator symbols (T2b); `@dynamicCallable` (T6); property-wrapper
  schema markers (T8); `@dynamicMemberLookup` on `RowView` (T5); function-registry DSL,
  Codable-codec macro, `DBError.description` macro (§Non-goals).

## Risks & non-goals

- **swift-syntax is the heavy dependency.** It would be ADSQL's first *large* external dep (far
  heavier than the swift-atomics call weighed in RFC 0005) and adds real clean-build time. Mitigation:
  the P0 core is dependency-free and is the default tier; the macro tier (P1/P2) is opt-in and
  separately justified.
- **Type-checker cost.** Operator-heavy builder blocks can blow up inference — build with
  `-Xfrontend -warn-long-expression-type-checking=100` (URLBuilder's guard) and keep overload sets tight.
- **Don't** macro-ize the hot `evaluate` switch (T9), put `@dynamicMemberLookup` on `RowView` (T5),
  introduce novel operator symbols (T2b), or generate the byte-precise record/key/catalog codecs
  (deliberate hand-tuning: collation tags, monotone-float bits, 0x00-escaping, varints, no-copy paths).
- **Non-goals (declined codegen):** function-registry result-builder (only 8 functions in
  `Functions.swift:302`; a `switch` likely beats closure dispatch — revisit only for user-defined
  functions); a Codable-style codec macro; a `DBError.description` macro (`Errors.swift:44` is
  idiomatic, several cases interpolate params).

## Declined — consolidated (with reasons)

| Proposal | Reason to decline | Ref |
|---|---|---|
| Function-registry result-builder (`Functions.swift:302`) | Only 8 functions; a `switch name` is likely *faster* than closure-dictionary dispatch and the bodies genuinely differ. Adopt only if user-defined SQL functions become a goal. | §Non-goals |
| Codable-style codec macro (RecordCodec/KeyCodec/Catalog) | Byte format is deliberately hand-tuned (collation tags, monotone-float bits, 0x00-escaping, varints, no-copy paths); a macro becomes a config-language as long as the code. | §Risks |
| `@DBError`/description macro (`Errors.swift:44`, 42 cases) | Idiomatic and readable; several cases interpolate params (`.io` uses `strerror`); a macro = per-case templates as long as the switch. | §Non-goals |
| `@propertyWrapper` schema markers | Changes field storage type + adds wrapper instance/accessors; peer macros do this with no storage cost. | T8 |
| `@dynamicCallable` / `db("…")` | Stringly/loosely typed; works against the type-safety goal. | T6 |
| Novel custom operator *symbols* (`<-`, `~~`, `%`) | Discoverability/tooling cost; named methods read better. | T2b |
| `@dynamicMemberLookup` on `RowView` | Throwing + `~Escapable` (Review 0001 F1); a non-throwing subscript would swallow errors or trap on the hot path. | T5 |
| `#predicate` macro (now) | Large closure→AST macro; the operator DSL covers ~90% with far less machinery. | T3b (deferred) |
| Macro-izing the hot `evaluate` switch | Hot path; each case is genuinely different logic — opacity for ~zero benefit. | T9 |

## Verification (when built)

- `swift build`; `swift test` — the suites **differentially mirror every result against real
  SQLite** (`CSQLite`), so any behavior-changing refactor (T9) fails loudly; TSan stays green.
- DSL: assert `SQL { … }` equals the `SQLStatementAST` parsed from the equivalent SQL string
  (round-trip), and executed rows match both the string form and SQLite. **Injection test:** a
  value carrying `"; DROP TABLE …"` is stored/returned as data, never executed.
- Macros: golden `assertMacroExpansion` tests in a new `ADSQLMacrosTests`; `@FixedLayout`
  byte-identity test vs the hand codec before swapping.
- Self-check: numbered 0006, house style matches RFC 0001–0005; carries credit (clean slate +
  reused seams), a Challenges section with an honest negative (Macros≠speed), and an explicit
  zero-dep tension for swift-syntax.

## References

Reference DSL: `github.com/g-cqd/URLBuilder` (`@resultBuilder` + freestanding `#URL` +
`@URLQuery`/`@Query` peer macro; SwiftPM `.macro` target on swift-syntax). Apple DSL family:
SwiftUI `ViewBuilder`, RegexBuilder `RegexComponentBuilder` (typed-output threading), SwiftData
`@Model`/`@Attribute`. swift-syntax: `github.com/swiftlang/swift-syntax` (`SwiftCompilerPlugin`,
`SwiftSyntaxMacros`).

Cross-refs: RFC 0005 (Apple-native API adoption — declined the *external* query-builder; this is
the in-tree answer), RFC 0004 (performance program — the real runtime levers), RFC 0003 (Swift
memory-safety/perf APIs; zero-dep stance, D2), Review 0001 (`@safe`/`~Escapable` borrowed-view
audit — F1, the RowView constraint), Review 0002 (performance & architecture).

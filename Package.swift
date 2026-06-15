// swift-tools-version: 6.3
import PackageDescription

// Maximum strictness, shared across every Swift target. Dependency-safe (no unsafe flags), so the
// library can still be consumed via a version-pinned SwiftPM requirement. `.v6` language mode turns on
// complete strict-concurrency checking; the upcoming features tighten existentials and import
// visibility. Aligned with the sibling `../adjson` package.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// The kernel's safety model, on top of `strictSettings`: SE-0458 strict memory safety (every unsafe
// construct is explicitly `unsafe` or `@safe`-encapsulated, so any new unsafe use is compiler-flagged)
// plus experimental lifetime dependence (SE-0446/0456) — the scope-bounded page views are
// `~Escapable` over `RawSpan` with `@_lifetime`, so the compiler enforces they cannot outlive their
// snapshot.
let kernelSettings: [SwiftSetting] =
    strictSettings + [
        .strictMemorySafety(),
        .enableExperimentalFeature("Lifetimes"),
    ]

// Compile-time type-check timing warnings (flag slow expressions / function bodies). These use unsafe
// flags, which would block version-based dependency resolution if placed on the shipped library, so
// they live only on the internal (non-exported) benchmark + test targets.
let timingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=100",
        "-Xfrontend", "-warn-long-expression-type-checking=100",
    ])
]

// Benchmarks: strict + timing warnings only (no runtime instrumentation, so timings stay clean).
let benchSettings: [SwiftSetting] = strictSettings + timingWarningFlags

// Tests: additionally enable runtime actor data-race checks.
let testSettings: [SwiftSetting] =
    strictSettings + timingWarningFlags + [.unsafeFlags(["-enable-actor-data-race-checks"])]

// Dev-only tooling is gated behind `ADSQL_DEV` so packages that depend on ADSQL never resolve it.
// The `format` / `lint` command plugins carry no external dependencies, so they are always available
// without the flag; build-time lint enforcement (the `LintBuild` plugin) attaches to the library only
// in dev/CI.
let isDev = Context.environment["ADSQL_DEV"] != nil

// ADSQL's only runtime dependency is the ADJSON package — specifically its Foundation-free,
// swift-syntax-free `ADJSONCore` product, which backs the SQL JSON functions (tape parser +
// SQLite-dialect path evaluator). The DocC plugin that builds the documentation site is dev/CI-only
// (gated behind ADSQL_DEV), so packages that depend on ADSQL never resolve it.
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/g-cqd/ADJSON.git", branch: "main")
]
if isDev {
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
}

let package = Package(
    name: "ADSQL",
    // Floor OSes match the sibling `../adjson` package: macOS one generation below the device
    // platforms (everything the engine needs — `Synchronization`'s Atomic/Mutex ship in macOS 15,
    // `Span`/`RawSpan` back-deploy further still — is available there), device platforms at the 2025
    // generation. No `@available`/2025-SDK-gated APIs are used, so the macOS-15 floor compiles.
    platforms: [
        .macOS(.v15),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "ADSQL", targets: ["ADSQL"]),
        .library(name: "ADSQLImport", targets: ["ADSQLImport"]),
        .library(name: "ADSQLSearch", targets: ["ADSQLSearch"]),
        .executable(name: "adsql", targets: ["ADSQLTool"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "ADCAtomics"),
        .target(
            name: "ADSQLKernel",
            dependencies: ["ADCAtomics", .product(name: "ADJSONCore", package: "ADJSON")],
            swiftSettings: kernelSettings),
        .target(
            name: "ADSQL", dependencies: ["ADSQLKernel"], swiftSettings: strictSettings,
            plugins: isDev ? ["LintBuild"] : []),
        .executableTarget(
            name: "ADSQLTool", dependencies: ["ADSQL", "ADSQLImport"], swiftSettings: strictSettings),
        .systemLibrary(name: "CSQLite"),
        // SQLite-file importer (M8 F1, RFC 0010): reads a source .db via CSQLite and writes an
        // ADSQL database. Kept out of ADSQLKernel so the read-only engine never links sqlite3.
        .target(
            name: "ADSQLImport", dependencies: ["ADSQLKernel", "CSQLite"], swiftSettings: strictSettings),
        // apple-docs search-pages serving (M8 INT, RFC 0010 §2): builds the §2.2 main query, binds the
        // §2.4 filter bag, and frames the §2.3 projection into the §2.5 response bytes — the Swift body
        // of apple-docs' frozen `ad_storage_search_pages` ABI. Depends on ADSQL only (NOT CSQLite), so it
        // stays link-clean exactly like the read engine.
        .target(
            name: "ADSQLSearch", dependencies: ["ADSQL"], swiftSettings: strictSettings),
        .executableTarget(
            name: "ADSQLBench", dependencies: ["ADSQL", "CSQLite"], swiftSettings: benchSettings),
        .target(
            name: "ADSQLTestSupport",
            dependencies: ["ADSQLKernel"],
            path: "Tests/ADSQLTestSupport",
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "ADSQLKernelTests",
            dependencies: ["ADSQLKernel", "ADSQLTestSupport", "CSQLite"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "ADSQLImportTests",
            dependencies: ["ADSQLImport", "ADSQLSearch", "ADSQLTestSupport", "CSQLite"],
            swiftSettings: testSettings
        ),

        // Developer tooling. The command plugins are dependency-free (they drive the toolchain's
        // bundled `swift format`), so they impose nothing on packages that depend on ADSQL.
        .plugin(
            name: "Format",
            capability: .command(
                intent: .custom(verb: "format", description: "Format Swift sources with swift-format"),
                permissions: [.writeToPackageDirectory(reason: "Format Swift sources with swift-format")])),
        .plugin(
            name: "Lint",
            capability: .command(
                intent: .custom(verb: "lint", description: "Check formatting (swift-format strict)"))),
        .plugin(name: "LintBuild", capability: .buildTool()),
    ]
)

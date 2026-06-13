// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ADSQL",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ADSQL", targets: ["ADSQL"]),
    .executable(name: "adsql", targets: ["ADSQLTool"]),
  ],
  targets: [
    .target(name: "ADCAtomics"),
    .target(
      name: "ADSQLKernel", dependencies: ["ADCAtomics"],
      // SE-0458: every unsafe construct in the kernel is now explicitly marked
      // `unsafe` (or encapsulated by a `@safe` type), so the compiler enforces
      // that any new unsafe use is called out. LifetimeDependence (SE-0446/0456)
      // lets the scope-bounded page views be `~Escapable` over `RawSpan` with
      // `@_lifetime`, so the compiler *enforces* they cannot outlive their
      // snapshot (Review 0001 F1/F2).
      swiftSettings: [
        .strictMemorySafety(),
        .enableExperimentalFeature("Lifetimes"),
      ]),
    .target(name: "ADSQL", dependencies: ["ADSQLKernel"]),
    .executableTarget(name: "ADSQLTool", dependencies: ["ADSQL"]),
    .systemLibrary(name: "CSQLite"),
    .executableTarget(name: "ADSQLBench", dependencies: ["ADSQL", "CSQLite"]),
    .target(
      name: "ADSQLTestSupport",
      dependencies: ["ADSQLKernel"],
      path: "Tests/ADSQLTestSupport"
    ),
    .testTarget(
      name: "ADSQLKernelTests",
      dependencies: ["ADSQLKernel", "ADSQLTestSupport", "CSQLite"]
    ),
  ]
)

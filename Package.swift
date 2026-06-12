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
    .target(name: "ADSQLKernel"),
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
      dependencies: ["ADSQLKernel", "ADSQLTestSupport"]
    ),
  ]
)

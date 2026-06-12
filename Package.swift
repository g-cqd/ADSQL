// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ADSQL",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ADSQL", targets: ["ADSQL"])
  ],
  targets: [
    .target(name: "ADSQLKernel"),
    .target(name: "ADSQL", dependencies: ["ADSQLKernel"]),
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

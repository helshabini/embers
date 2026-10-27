// swift-tools-version: 6.0
import PackageDescription

// `swift test` needs XCTest or swift-testing, and neither ships with the Command Line Tools, so the
// checks run as the `selfcheck` executable until Xcode is installed.
let package = Package(
    name: "EmbersCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EmbersCore", targets: ["EmbersCore"]),
        .library(name: "EmbersData", targets: ["EmbersData"]),
        .executable(name: "validate-import", targets: ["ValidateImport"]),
        .executable(name: "selfcheck", targets: ["SelfCheck"]),
        .executable(name: "seed-store", targets: ["SeedStore"]),
        .executable(name: "benchmark", targets: ["Benchmark"]),
    ],
    targets: [
        // Each library carries its own catalog: what the rules say in words is translated where the
        // rules are, and read through `Bundle.module`.
        .target(name: "EmbersCore", resources: [.process("Localizable.xcstrings")]),
        .target(
            name: "EmbersData",
            dependencies: ["EmbersCore"],
            resources: [.process("Localizable.xcstrings")]
        ),
        .executableTarget(name: "ValidateImport", dependencies: ["EmbersCore"]),
        .executableTarget(name: "SelfCheck", dependencies: ["EmbersCore", "EmbersData"]),
        .executableTarget(name: "SeedStore", dependencies: ["EmbersCore", "EmbersData"]),
        .executableTarget(name: "Benchmark", dependencies: ["EmbersCore", "EmbersData"]),
    ],
    swiftLanguageModes: [.v6]
)

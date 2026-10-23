// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Bollard", platforms: [.macOS(.v14)],
  products: [.executable(name: "Bollard", targets: ["Bollard"])],
  targets: [
    .target(name: "ProcessBridge"), .target(name: "BollardCore", dependencies: ["ProcessBridge"]),
    .executableTarget(name: "Bollard", dependencies: ["BollardCore"]),
    .executableTarget(name: "BollardBench", dependencies: ["BollardCore"]),
    .executableTarget(
      name: "BollardChecks", dependencies: ["BollardCore", "ProcessBridge"],
      path: "Tests/BollardChecks"),
  ], swiftLanguageModes: [.v6])

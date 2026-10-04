// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DevPorts", platforms: [.macOS(.v14)],
  products: [.executable(name: "DevPorts", targets: ["DevPorts"])],
  targets: [
    .target(name: "ProcessBridge"), .target(name: "DevPortsCore", dependencies: ["ProcessBridge"]),
    .executableTarget(name: "DevPorts", dependencies: ["DevPortsCore"]),
    .executableTarget(name: "DevPortsBench", dependencies: ["DevPortsCore"]),
    .executableTarget(
      name: "DevPortsChecks", dependencies: ["DevPortsCore", "ProcessBridge"],
      path: "Tests/DevPortsCoreTests"),
  ], swiftLanguageModes: [.v6])

// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClaudeIsolationPoC",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClaudeIsolationPoC", targets: ["ClaudeIsolationPoC"])],
    targets: [.executableTarget(name: "ClaudeIsolationPoC")]
)

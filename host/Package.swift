// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeIsolationPoC",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "vm-poc", targets: ["VMPoC"]),
               .executable(name: "vm-text-runtime", targets: ["VMTextRuntime"])],
    targets: [.executableTarget(name: "VMPoC"), .executableTarget(name: "VMTextRuntime")]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdgeDiagnostics",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EdgeDiagnostics", targets: ["EdgeDiagnostics"])],
    targets: [
        .executableTarget(name: "EdgeDiagnostics", resources: [.process("Resources")]),
        .testTarget(name: "EdgeDiagnosticsTests", dependencies: ["EdgeDiagnostics"])
    ]
)

// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "TelemetryCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "TelemetryCore", targets: ["TelemetryCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "TelemetryCore", dependencies: ["CSQLite"]),
        .testTarget(name: "TelemetryCoreTests", dependencies: ["TelemetryCore"])
    ]
)

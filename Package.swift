// swift-tools-version: 6.0
import PackageDescription
import Foundation

let package = Package(
    name: "Roamtty",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "RoamttyCore", targets: ["RoamttyCore"]),
        .library(name: "RoamttyTransport", targets: ["RoamttyTransport"]),
    ],
    targets: [
        .target(name: "CNative", publicHeadersPath: "include", linkerSettings: [
            .linkedLibrary("ssh2"), .linkedLibrary("crypto"), .linkedLibrary("ssl"), .linkedLibrary("z"), .linkedLibrary("sqlite3")
        ]),
        .target(name: "RoamttyCore", dependencies: ["CNative"], resources: [.process("Resources")]),
        .target(name: "RoamttyTransport", dependencies: ["RoamttyCore", "CNative"]),
        .testTarget(name: "RoamttyCoreTests", dependencies: ["RoamttyCore"]),
        .testTarget(name: "RoamttyTransportTests", dependencies: ["RoamttyTransport"]),
    ],
    swiftLanguageModes: [.v5]
)

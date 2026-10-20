// swift-tools-version:5.9
// Checks the app's terminal URL finder, wide cell repair and scrollback count against SwiftTerm's real emulator;
// run through scripts/test-terminal-url.sh.
import PackageDescription
import Foundation

let swiftTerm = ProcessInfo.processInfo.environment["ROAMTTY_SWIFTTERM"] ?? "SwiftTerm"
let package = Package(
    name: "TerminalUrlChecks",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: swiftTerm)],
    targets: [
        .executableTarget(name: "TerminalUrlChecks", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "TerminalWideCellChecks", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "TerminalScrollbackChecks", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
    ]
)

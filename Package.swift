// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
#if os(macOS)
let nativeC: [CSetting] = [.headerSearchPath("../../Vendor/macosx/include")]
let nativeSwift: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I" + root + "/Vendor/macosx/include"])]
let nativeLink: [LinkerSetting] = [.unsafeFlags(["-L" + root + "/Vendor/macosx/lib"])]
#else
let nativeC: [CSetting] = [.headerSearchPath("../../Vendor/linux/include")]
let nativeSwift: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I" + root + "/Vendor/linux/include"])]
let nativeLink: [LinkerSetting] = [.unsafeFlags(["-L" + root + "/Vendor/linux/lib"])]
#endif
let package = Package(
    name: "Roamtty",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "RoamttyCore", targets: ["RoamttyCore"]),
        .library(name: "RoamttyTransport", targets: ["RoamttyTransport"]),
    ],
    targets: [
        .target(name: "CNative", publicHeadersPath: "include", cSettings: nativeC, linkerSettings: nativeLink + [
            .linkedLibrary("ssh2"), .linkedLibrary("crypto"), .linkedLibrary("z"), .linkedLibrary("sqlite3")
        ]),
        .target(name: "RoamttyCore", dependencies: ["CNative"], resources: [.process("Resources")], swiftSettings: nativeSwift),
        .target(name: "RoamttyTransport", dependencies: ["RoamttyCore", "CNative"], swiftSettings: nativeSwift),
        .testTarget(name: "RoamttyCoreTests", dependencies: ["RoamttyCore"], swiftSettings: nativeSwift),
        .testTarget(name: "RoamttyTransportTests", dependencies: ["RoamttyTransport"], swiftSettings: nativeSwift),
    ],
    swiftLanguageModes: [.v5]
)

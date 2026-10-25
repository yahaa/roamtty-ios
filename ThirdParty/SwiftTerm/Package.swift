// swift-tools-version:5.9
import PackageDescription

#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
let resources: [Resource] = []
#else
let platformExcludes = ["Mac/README.md"]
let resources: [Resource] = [.process("Apple/Metal/Shaders.metal")]
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v13), .tvOS(.v13), .visionOS(.v1)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm",
                      exclude: platformExcludes, resources: resources)],
    swiftLanguageVersions: [.v5]
)

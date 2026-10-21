// swift-tools-version:5.9
import PackageDescription

let release: [SwiftSetting] = [.unsafeFlags(["-Ounchecked", "-wmo"], .when(configuration: .release))]
// Newer AI frameworks are optional so the apps still launch on macOS 14.
let weakAI: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                                             "-Xlinker", "-weak_framework", "-Xlinker", "ImagePlayground"])]

let package = Package(
    name: "EaselStudio",
    platforms: [.macOS(.v14)],
    targets: [
        // Looks, adjustments, bitmap helpers and the Easel ↔ Reel link, shared by both apps.
        .target(name: "EaselKit", path: "Sources/EaselKit", swiftSettings: release),
        .executableTarget(name: "Easel", dependencies: ["EaselKit"], path: "Sources/Easel",
                          swiftSettings: release, linkerSettings: weakAI),
        .executableTarget(name: "Reel", dependencies: ["EaselKit"], path: "Sources/Reel",
                          swiftSettings: release, linkerSettings: weakAI),
        .executableTarget(name: "Tone", dependencies: ["EaselKit"], path: "Sources/Tone",
                          swiftSettings: release, linkerSettings: weakAI),
        .executableTarget(name: "Flip", dependencies: ["EaselKit"], path: "Sources/Flip",
                          swiftSettings: release, linkerSettings: weakAI),
        .executableTarget(name: "Quill", dependencies: ["EaselKit"], path: "Sources/Quill", swiftSettings: release),
        .executableTarget(name: "Folio", dependencies: ["EaselKit"], path: "Sources/Folio", swiftSettings: release),
    ]
)

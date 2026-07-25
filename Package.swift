// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "local-translator",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TranslationCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

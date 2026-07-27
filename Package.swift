// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "local-translator",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TranslationCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "OllamaKit", dependencies: ["TranslationCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OllamaKitTests", dependencies: ["OllamaKit", "TranslationCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "translate-cli", dependencies: ["TranslationCore", "OllamaKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "acceptance", dependencies: ["TranslationCore", "OllamaKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "TranslatorApp", dependencies: ["TranslationCore", "OllamaKit"],
                          exclude: ["Info.plist"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TranslatorAppTests", dependencies: ["TranslatorApp", "TranslationCore", "OllamaKit"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

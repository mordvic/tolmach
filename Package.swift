// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "local-translator",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TranslationCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "OllamaKit", dependencies: ["TranslationCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "OllamaKitTests", dependencies: ["OllamaKit", "TranslationCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        // Deliberately does **not** depend on OllamaKit: the two transports share the
        // `LLMClient` protocol in TranslationCore and nothing else. A dependency here would let
        // one server's shape leak into the other's client, which is the whole failure the
        // second engine's design set out to avoid.
        .target(name: "LMStudioKit", dependencies: ["TranslationCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LMStudioKitTests", dependencies: ["LMStudioKit", "TranslationCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "translate-cli", dependencies: ["TranslationCore", "OllamaKit", "LMStudioKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "acceptance", dependencies: ["TranslationCore", "OllamaKit", "LMStudioKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        // The first non-app target to import AppKit, and a deliberate `docs/adr/0007`
        // whitelist edit rather than an oversight: an attributed string *is* AppKit, and the
        // alternative was a second Markdown serialiser inside the app for the rich-copy
        // flavour. It depends on `TranslationCore` for `MarkdownBlockScanner` and on nothing
        // in the app layer — `MarkdownFontConfig` mirrors `ContentFont` instead of importing
        // it, which is what keeps the dependency arrow pointing one way.
        .target(name: "MarkupKit", dependencies: ["TranslationCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MarkupKitTests", dependencies: ["MarkupKit", "TranslationCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "TextCapture", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "TextCaptureTests", dependencies: ["TextCapture"], swiftSettings: [.swiftLanguageMode(.v6)]),
        // `Resources` is excluded rather than declared with `resources:` because this target is
        // never consumed as a SwiftPM bundle: `Scripts/make-app-bundle.sh` assembles the .app
        // by hand and copies `Resources/ru.lproj` in itself. Declared as a SwiftPM resource it
        // would land in a `LocalTranslator_TranslatorApp.bundle` that the assembled app does
        // not look inside, and `Bundle.main.localizations` — the whole reason the directory
        // exists — would still answer empty.
        .executableTarget(name: "TranslatorApp", dependencies: ["TranslationCore", "OllamaKit", "LMStudioKit", "TextCapture", "MarkupKit"],
                          exclude: ["Info.plist", "Resources"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "TranslatorAppTests", dependencies: ["TranslatorApp", "TranslationCore", "OllamaKit", "LMStudioKit", "TextCapture", "MarkupKit"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        // Depends on no product: it reads Package.swift and the documents as text, and exists
        // so that documentation drift fails the build the way a broken test does.
        .testTarget(name: "DocumentationTests", swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)

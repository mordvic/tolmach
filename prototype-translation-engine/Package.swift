// swift-tools-version: 6.0
import PackageDescription

// PROTOTYPE — throwaway. See README.md for the question this answers.
let package = Package(
    name: "prototype-translation-engine",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic. No I/O. This is the part meant to survive the prototype.
        .target(
            name: "TranslationEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Thin adapter over the Ollama HTTP API. Implements TranslationEngine's LLMClient seam.
        .target(
            name: "OllamaClient",
            dependencies: ["TranslationEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Throwaway TUI shell.
        .executableTarget(
            name: "PrototypeTUI",
            dependencies: ["TranslationEngine", "OllamaClient"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Throwaway A/B harness: document glossary and corrector second pass.
        .executableTarget(
            name: "Experiment",
            dependencies: ["TranslationEngine", "OllamaClient"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

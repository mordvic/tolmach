// Sources/TranslatorApp/WarmUpPlan.swift
import Foundation

/// Which models to put in memory at launch, in order.
///
/// A rule extracted from `TranslatorApp.warmUp()` so that a test can read it — the same shape,
/// and the same reason, as `PrimaryAction.forMode`: the decision matters, and a private method
/// on a scene is unreachable from a test process.
enum WarmUpPlan {
    /// Empty when warming is switched off, and empty when no model has been chosen — LM Studio
    /// starts with no default, and asking a server to load «» is a refusal with a confusing
    /// message on it.
    ///
    /// **How many models is a per-engine decision, and the reason is memory rather than
    /// transport.** On Ollama: both models a hotkey can reach, when they differ — ⌥⌘T's and
    /// ⌥⌘R's — because two that fit stay resident together (measured 2026-08-18). On LM Studio:
    /// the перевод model alone, because the models there are larger — every LLM on this install
    /// is MLX and the 27B class is 22.81 GB apiece against 48 GB of machine — so warming two
    /// would either fail or push the system into swap, and it would do so at *login*, before
    /// the user had asked for anything. The правка model loads on the first ⌥⌘R instead and
    /// pays 5.6–8.1 s once.
    static func models(for settings: AppSettings) -> [String] {
        guard settings.warmUpOnLaunch, !settings.hasNoTranslationModel else { return [] }
        var models = [settings.interactiveModel]
        if settings.engine == .ollama, settings.proofreadModelDiffersFromInteractive {
            models.append(settings.resolvedProofreadModel)
        }
        return models
    }
}

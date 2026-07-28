import Foundation

public enum ModelRole: Sendable { case interactive, background }

public enum ModelPolicy {
    public static func defaultModel(for role: ModelRole) -> String {
        switch role {
        case .interactive: "aya-expanse:8b"
        case .background: "gpt-oss:20b"
        }
    }

    /// Model-name prefix → the measured reason that model is marked.
    ///
    /// English, and it does **not** reach the settings pane — an earlier version of this
    /// comment said it did. The app renders `RussianCopy.blacklistReasons`, keyed by these
    /// same prefixes; this text is what `translate-cli` prints on a terminal, and the
    /// fallback the app shows if a prefix here ever lacks a Russian counterpart. That
    /// fallback is deliberate: a warning in the wrong language beats silence, which would
    /// leave a model that mangles identifiers looking approved.
    ///
    /// Matched by prefix so every tag of a bad model is covered.
    public static let blacklist: [String: String] = [
        "gemma3n": "Corrupts identifiers character-by-character (e.g. `StructureDefiinition` inside inline code). Unsafe for technical documentation.",
        "qwen3:30b": "78 seconds of reasoning before the first character of translation. Too slow for any interactive use.",
    ]

    public static func blacklistReason(for model: String) -> String? {
        for (prefix, reason) in blacklist where model.hasPrefix(prefix) { return reason }
        return nil
    }
}

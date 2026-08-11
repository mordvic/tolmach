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

    /// Model-name prefixes that **ignore** `"think": false` and can only be graded by level.
    ///
    /// Measured 2026-08-11: `gpt-oss:20b` kept 563 characters of trace under `false` — more
    /// than the 478 it produces when nothing is sent — against 15 / 441 / 889 for
    /// `low` / `medium` / `high`. Ollama's documentation says the same for the family, which is
    /// why this is a prefix rather than the one tag that was measured.
    public static let thinkingLevelsOnly: [String] = ["gpt-oss"]

    /// Model-name prefix → why switching reasoning off on it is worse than leaving it on.
    ///
    /// Unlike `blacklist`, these strings reach no user interface: they are for the next reader
    /// of this file. They are here rather than in a comment because a table of bare prefixes is
    /// a table nobody dares change.
    public static let thinkingDisableLeaks: [String: String] = [
        "qwen3:30b": "«think: false» moves the reasoning out of message.thinking and into message.content, i.e. into the translation itself. Measured 2026-08-11: 2798 characters of Russian reasoning in place of a one-sentence answer.",
    ]

    /// What to put in `ChatOptions.think` for one model, given what the user asked for.
    ///
    /// The order of the two tables is load-bearing: a model in both must be *graded*, because
    /// that is the branch that produces a working instruction, while «leave it alone» produces
    /// none. Nothing is in both today; the order is what keeps that safe if something ever is.
    public static func thinkRequest(for model: String,
                                    quiet: Bool,
                                    level: ThinkRequest.Level) -> ThinkRequest? {
        guard quiet else { return nil }
        if thinkingLevelsOnly.contains(where: { model.hasPrefix($0) }) { return .level(level) }
        if thinkingDisableLeaks.keys.contains(where: { model.hasPrefix($0) }) { return nil }
        return .off
    }
}

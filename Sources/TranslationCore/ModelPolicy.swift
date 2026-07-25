import Foundation

public enum ModelRole: Sendable { case interactive, background }

public enum ModelPolicy {
    public static func defaultModel(for role: ModelRole) -> String {
        switch role {
        case .interactive: "aya-expanse:8b"
        case .background: "gpt-oss:20b"
        }
    }

    /// model-name prefix → reason shown in settings
    public static let blacklist: [String: String] = [
        "gemma3n": "Port: corrupts identifiers character-by-character (e.g. `StructureDefiinition` inside inline code). Unsafe for technical documentation.",
        "qwen3:30b": "78 seconds of reasoning before the first character of translation. Too slow for any interactive use.",
    ]

    public static func blacklistReason(for model: String) -> String? {
        for (prefix, reason) in blacklist where model.hasPrefix(prefix) { return reason }
        return nil
    }
}

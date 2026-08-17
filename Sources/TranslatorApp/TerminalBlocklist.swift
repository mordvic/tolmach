// Sources/TranslatorApp/TerminalBlocklist.swift

/// Known terminal-emulator bundle identifiers — issue #29. «Заменить» refuses to write into
/// any of these: a terminal has no editable selection to replace, pasted content lands
/// wherever the shell's cursor happens to be, and — depending on the shell and session in
/// front of the panel — an embedded newline in a multi-line result can be read as a physical
/// Enter press rather than as inert text. Bracketed paste mode covers the common case (on by
/// default in zsh ≥5.1 and bash ≥5.1/readline ≥8.1) but not macOS's own bundled `/bin/bash`
/// (3.2, unmaintained since Apple stopped tracking GPLv3 bash), an SSH session, tmux/screen,
/// or any program reading raw stdin outside readline. See the issue for the full reasoning.
///
/// Identifiers verified against each project's own packaging rather than guessed — Alacritty
/// and WezTerm from their own repositories' `Info.plist`, the rest from their published
/// deployment catalogues, Terminal.app and iTerm2 confirmed against locally installed copies.
/// Errs toward a broad list per the accepted design decision: the cost of including one more
/// identifier is nothing, and the cost of missing a real terminal is the exact risk this
/// exists to close.
enum TerminalBlocklist {
    static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        "org.tabby",
    ]

    /// `nil` — no frontmost application, or one that answered no bundle identifier — is not
    /// blocked: there is nothing here to recognise as a terminal, and refusing on `nil` would
    /// disable «Заменить» for every application this list has not been told about, which is
    /// the opposite of what a *block*list means.
    static func isBlocked(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }
}

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
/// Each identifier below is commented with where it came from — not guessed, but also not
/// backed by a rerunnable check the way this project's other "measured" facts are, since these
/// are nine other projects' packaging rather than something in this repo. Errs toward a broad
/// list per the accepted design decision: the cost of including one more identifier is
/// nothing, and the cost of missing a real terminal is the exact risk this exists to close.
enum TerminalBlocklist {
    // Verified per-identifier at the time this was written, not merely asserted — but there
    // is no in-repo probe re-running any of this, unlike every other "measured" claim this
    // project makes, because these are nine other projects' packaging, not something this
    // app's own build can query. A bundle identifier can change across a major version; if
    // «Заменить» is ever reported not refusing in one of these, that terminal's current
    // `Info.plist` is the thing to re-check, per `docs/reference/OPEN-ITEMS.md`.
    static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",       // confirmed on this machine's own Terminal.app
        "com.googlecode.iterm2",    // confirmed on this machine's own iTerm.app
        "org.alacritty",            // alacritty/alacritty, extra/osx/Alacritty.app/Contents/Info.plist
        "net.kovidgoyal.kitty",     // kovidgoyal/kitty's own published identifier
        "com.github.wez.wezterm",   // wez/wezterm, assets/macos/WezTerm.app/Contents/Info.plist
        "dev.warp.Warp-Stable",     // Warp's published macOS deployment identifier
        "co.zeit.hyper",            // vercel/hyper's published macOS deployment identifier
        "com.mitchellh.ghostty",    // Ghostty's published macOS deployment identifier
        "org.tabby",                // Tabby's (formerly Terminus) published deployment identifier
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

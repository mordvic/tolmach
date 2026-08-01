// Sources/TranslatorApp/Log.swift
import Foundation
import os

/// The app's diagnostic log.
///
/// Until this existed there was none: no `os.Logger` anywhere in `Sources`, and the only
/// `print` in the package was in the acceptance harness. That is defensible in a program you
/// can watch run, and this one is not — it is `LSUIElement`, it stays resident for days, and
/// four of its paths swallow a failure on purpose. Each of those four swallows is individually
/// right; together, with nothing recording them, they make a class of failure that cannot be
/// reported by the person meeting it. The worst of them takes away the app's only entry point:
/// a refused hotkey registration leaves no shortcut, no message and no trace.
///
/// **This adds `os` to the whitelist in `CLAUDE.md`, which is a deliberate edit and not a
/// formality.** It is a system framework, it ships with the platform, and it introduces no
/// dependency to resolve — but the rule says the list is closed, so the list is amended rather
/// than quietly ignored.
///
/// ## What may be logged
///
/// **Never the user's text.** Not the selection, not the source, not the translation, not a
/// glossary term. The whole product promise is that text does not leave the machine, and a
/// unified-log entry is readable by any admin on the box and is collected by sysdiagnose — so
/// «it never leaves the machine» would stop being true in the one way nobody would think to
/// check. What is logged is what *happened*: which operation, and why it stopped.
///
/// Error descriptions are marked `.public` on purpose. `Logger`'s default for an interpolated
/// value is `.private`, which renders as `<private>` in `log show` and would make every entry
/// here useless for the diagnosis it exists to serve. They are safe to reveal because the only
/// values reaching them are `OllamaError` cases and `URLError` descriptions — transport
/// failures naming a loopback address — never anything derived from what the user translated.
///
/// ## Reading it
///
///     log show --last 1h --predicate 'subsystem == "com.mordvic.localtranslator"' --info
///     log stream --predicate 'subsystem == "com.mordvic.localtranslator"'
enum Log {
    /// The bundle identifier from `Info.plist`. Written out rather than read from
    /// `Bundle.main.bundleIdentifier`, which is nil when the code runs from the test bundle or
    /// from `swift run` — and a nil subsystem makes the predicate above match nothing, which is
    /// the one failure mode a logging facility must not have.
    static let subsystem = "com.mordvic.localtranslator"

    /// The shortcut, the capture, and the panel they feed.
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    /// Translation runs and everything `TranslationCore` reports back about them.
    static let engine = Logger(subsystem: subsystem, category: "engine")
    /// Settings and the glossary file.
    static let settings = Logger(subsystem: subsystem, category: "settings")
}

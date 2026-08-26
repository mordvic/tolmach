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
/// here useless for the diagnosis it exists to serve. They are safe to reveal because none of
/// them is derived from what the user translated: they are `OllamaError` cases, `URLError`
/// descriptions, and the message an engine sent back about a request.
///
/// **That last kind is not bounded, and must go through `capped(_:)`.** LM Studio's mid-stream
/// `error` frame carries a server-chosen string of any length; interpolated whole it would put
/// as much of it into the unified log as the server cared to send. `capped` is the only thing
/// standing between «diagnosable» and «a log-writing primitive on the loopback port».
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
    /// The file queue: what it could not read and what it could not write.
    ///
    /// A category of its own because these are the failures a user reports as «оно ничего
    /// не сохранило», and finding them in the `engine` stream among per-часть diagnostics
    /// is the difference between a diagnosis and a search.
    ///
    /// **A file name is user data.** Nothing here logs one: a path names a document, a
    /// project and often an employer, and this file's own rule is that nothing derived
    /// from the user's text reaches the unified log.
    static let files = Logger(subsystem: subsystem, category: "files")

    /// The most of a server-supplied string that is worth writing down.
    ///
    /// Long enough for the messages both engines actually send — `unrecognized_keys`,
    /// `invalid_value`, «pull model manifest: file does not exist» are all well under it — and
    /// short enough that a server sending a megabyte writes 240 characters instead.
    static let maxServerMessage = 240

    /// One server-supplied string, bounded. The ellipsis is deliberate: a truncated message a
    /// reader mistakes for the whole one is worse than a long one.
    static func capped(_ message: String) -> String {
        message.count <= maxServerMessage
            ? message
            : String(message.prefix(maxServerMessage)) + "…"
    }
}

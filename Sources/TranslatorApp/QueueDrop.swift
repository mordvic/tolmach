// Sources/TranslatorApp/QueueDrop.swift
import Foundation

/// What the file queue will accept when files are dropped on it.
///
/// The sibling of `DroppedDocument` and deliberately not the same type: the two answer
/// the same question for two surfaces whose reasoning differs, and the differences are
/// the ceiling and the mixed-drop rule below.
enum QueueDrop {
    /// 2 MB per file.
    ///
    /// `DroppedDocument.maximumBytes` is 256 KB, and its comment justifies that number
    /// with what a person waits for **at a window**: no progress, no cancel, one
    /// translation appearing or not. The queue is the surface where waiting is the
    /// arrangement — it draws a bar per file, a state per file and a cancel button — so
    /// carrying the number across while discarding the reasoning that produced it would
    /// leave a limit nobody could re-derive.
    ///
    /// 2 MB is about 2300 model calls for an ASCII source at the default 900-character
    /// часть. That is a choice about what is worth offering, not a measurement: long,
    /// visible and interruptible. A file over it is refused rather than truncated, for
    /// `DroppedDocument`'s reason — presenting the first quarter of someone's document
    /// as the translation is the worse failure.
    static let maximumBytes = 2 * 1024 * 1024

    /// One dropped file. A `nil` `text` means it could not be read, and the queue shows
    /// it as an `.unreadable` row rather than discarding it.
    struct Item: Equatable {
        let url: URL
        let text: String?
    }

    /// Whether this drop is worth taking at all, decided **without reading a byte**.
    ///
    /// **A mixed drop is accepted and its refusals are named.** Ten `.md` files and one
    /// `.pdf` yields eleven items, one of them textless. An earlier version refused the
    /// whole drop on `SourcePane`'s rule that «taking the acceptable ones is a guess about
    /// which was meant» — but that rule is about *one slot and many candidates*, and a queue
    /// has a slot per file and no ambiguity at all. What the transplant cost is the part
    /// that decided it: `dropDestination`'s `Bool` is the entire error channel here, and a
    /// spring-back is legible feedback for one file and a riddle for ten — everything
    /// returns and nothing says which one was the problem. `false` here is that
    /// spring-back, kept for the one case where a row would explain nothing: a drop with
    /// nothing plausible in it at all.
    ///
    /// `dropDestination` must answer synchronously on the main actor, and the full check
    /// cannot: it loads and UTF-8-decodes every file, up to 2 MB each and any number of
    /// them, which froze the window before the drop animation had finished. So the
    /// synchronous half asks only what the filesystem can answer from an attribute — the
    /// extension and the size — and everything that needs the bytes happens in `read`, off
    /// the actor, where a file that turns out not to be text becomes a visible row saying so
    /// rather than a spring-back.
    static func acceptable(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.contains(where: plausible)
    }

    /// The full check, including the bytes. Never call this on the main actor.
    static func read(_ urls: [URL]) -> [Item] {
        urls.map { Item(url: $0, text: readable($0)) }
    }

    /// Same extension list, same UTF-8-or-nothing and same blank-file rule as
    /// `DroppedDocument`; only the ceiling differs. The size is read from the file's
    /// attributes before the bytes are, so a 40 MB file is refused without ever being
    /// loaded.
    private static func readable(_ url: URL) -> String? {
        guard plausible(url) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// The half of the check that costs nothing: the extension, and the size read from the
    /// file's attributes rather than by loading it. A 40 MB file is refused without ever
    /// being opened.
    private static func plausible(_ url: URL) -> Bool {
        guard DroppedDocument.readableExtensions.contains(url.pathExtension.lowercased())
        else { return false }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        else { return false }
        return size <= maximumBytes
    }
}

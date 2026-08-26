// Sources/TranslatorApp/DroppedDocument.swift
import Foundation

/// What the source pane will accept when a file is dropped on it, and what it reads out of one.
///
/// A type of its own rather than a closure inside `.dropDestination`, for the reason every
/// other decision in this app is: the rules — which files, how large, what counts as text —
/// are checkable, and a rule written inside a view modifier can only be read.
///
/// **Failure is reported by refusing the drop, not by a message.** `dropDestination`'s
/// `Bool` return is the platform's own way to say no: the dragged item springs back to where
/// it came from, which is the feedback a Mac user already knows. That is why nothing here
/// throws or produces an error string — there is no error surface in the window for it to go
/// to, and inventing one to say «this file is not text» would be a worse trade than the
/// spring-back the system draws for free.
enum DroppedDocument {
    /// Extensions this pane will read.
    ///
    /// A closed list, and short on purpose. The alternative — accept anything and let the
    /// UTF-8 decode below decide — reads whatever the user dropped, which for a large binary
    /// means loading it into memory to discover it is not text. Worse, some binaries *do*
    /// decode as UTF-8 and would arrive in the source pane as mojibake with a «Перевести»
    /// button next to them.
    ///
    /// `.text` is here because TextEdit still writes it. No `.rtf`: it decodes as UTF-8
    /// perfectly well and would fill the pane with `\rtf1\ansi…`.
    static let readableExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    /// 256 KB.
    ///
    /// Not a memory limit — it is a limit on what is worth offering to translate. At the
    /// default 900-character chunk this is already about 290 requests to the model, which at
    /// the measured throughput is far past anything a person waits for at a window. A file
    /// over this is refused rather than truncated: silently translating the first quarter of
    /// someone's document and presenting it as the translation is the worse failure.
    static let maximumBytes = 256 * 1024

    /// The text of a dropped file, or nil if this pane will not take it.
    ///
    /// Nil covers every refusal on purpose — wrong extension, too large, not UTF-8, not
    /// readable at all — because the caller does the same thing with all of them, and a
    /// distinction the caller cannot act on is a distinction that only makes the type harder
    /// to test.
    ///
    /// The size is read from the file's attributes before the bytes are, so an ordinary
    /// enormous file is refused without ever being loaded — and re-checked after the read,
    /// because that first look is evidence rather than a guarantee.
    static func text(of url: URL) -> String? {
        guard plausible(url) else { return nil }
        guard let data = try? Data(contentsOf: url),
              // Defence in depth, and **not pinned by a test**: with `plausible` resolving
              // links, every file this refuses is one it already refused a step earlier, so a
              // test written for this line stayed green with the line deleted. What it still
              // covers is the window between the stat and the read — a file that grows, or a
              // path that becomes a link — which a test process cannot open without racing
              // the filesystem. `QueueDrop.readable` carries the same unpinned pair.
              data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        // A file of blank lines is readable and has nothing to translate. Refusing it here is
        // the same judgement `SelectionReader.meaningful` makes about a selection, and for the
        // same reason: an empty source pane with a spring-back says more than an empty source
        // pane without one.
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// The half of the check that costs nothing: the extension, and the size read from the
    /// file's attributes rather than by loading it. A 40 MB file is refused without ever being
    /// opened.
    ///
    /// **Separate from `text(of:)` so that «without ever being opened» is a checkable claim.**
    /// Folded into the guard above it was not: the `data.count` re-check refuses the same file
    /// a moment later, so a test asserting only «refused» stayed green with the resolution
    /// deleted — `docs/reference/TESTING.md`'s «green for the wrong reason» exactly. `QueueDrop`
    /// splits the same pair for the same reason.
    static func plausible(_ url: URL) -> Bool {
        guard readableExtensions.contains(url.pathExtension.lowercased()) else { return false }
        // Resolved first. `attributesOfItem` reports on the link, not on its target, while
        // `Data(contentsOf:)` follows it — so a symlink named `notes.md` pointing at a
        // multi-gigabyte file answered «102 bytes» here and then loaded the lot. Measured.
        // `QueueDrop.plausible` already resolved for exactly this reason; this pane had
        // neither half of the pair.
        guard let size = (try? FileManager.default
                            .attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? Int
        else { return false }
        return size <= maximumBytes
    }
}

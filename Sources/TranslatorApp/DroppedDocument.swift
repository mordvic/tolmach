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
    /// The size is read from the file's attributes before the bytes are, so an enormous file
    /// is refused without ever being loaded.
    static func text(of url: URL) -> String? {
        guard readableExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= maximumBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        // A file of blank lines is readable and has nothing to translate. Refusing it here is
        // the same judgement `SelectionReader.meaningful` makes about a selection, and for the
        // same reason: an empty source pane with a spring-back says more than an empty source
        // pane without one.
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

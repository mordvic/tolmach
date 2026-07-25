import Foundation

public struct Chunk: Sendable, Equatable {
    public let index: Int
    public let text: String
    public let containsCodeFence: Bool
}

/// Splits long text for translation.
///
/// The rule that matters: a fenced code block is atomic. Splitting inside one
/// hands the model an unterminated fence, and it reliably "repairs" it by
/// translating the code. Everything else splits on blank lines, falling back to
/// sentence boundaries only when a single paragraph blows the budget on its own.
public enum Chunker {
    public static func chunk(_ text: String, maxCharacters: Int) -> [Chunk] {
        let blocks = blocks(in: text)
        var chunks: [Chunk] = []
        var current = ""
        var currentHasFence = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            chunks.append(Chunk(index: chunks.count, text: trimmed, containsCodeFence: currentHasFence))
            current = ""
            currentHasFence = false
        }

        for block in blocks {
            // An oversized prose block is split further; an oversized code block is not.
            let pieces: [Block]
            if block.text.count > maxCharacters && !block.isCodeFence {
                pieces = splitBySentences(block.text, maxCharacters: maxCharacters)
                    .map { Block(text: $0, isCodeFence: false) }
            } else {
                pieces = [block]
            }

            for piece in pieces {
                if !current.isEmpty && current.count + piece.text.count + 2 > maxCharacters {
                    flush()
                }
                if !current.isEmpty { current += "\n\n" }
                current += piece.text
                currentHasFence = currentHasFence || piece.isCodeFence
            }
        }
        flush()

        if chunks.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks = [Chunk(index: 0, text: trimmed, containsCodeFence: false)]
            }
        }
        return chunks
    }

    struct Block {
        let text: String
        let isCodeFence: Bool
    }

    /// Paragraphs, with fenced code blocks kept whole regardless of blank lines inside them.
    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var buffer: [String] = []
        var fenceBuffer: [String] = []
        var insideFence = false

        func flushProse() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(Block(text: joined, isCodeFence: false)) }
            buffer = []
        }

        for line in text.components(separatedBy: .newlines) {
            let isFenceMarker = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")

            if insideFence {
                fenceBuffer.append(line)
                if isFenceMarker {
                    blocks.append(Block(text: fenceBuffer.joined(separator: "\n"), isCodeFence: true))
                    fenceBuffer = []
                    insideFence = false
                }
                continue
            }

            if isFenceMarker {
                flushProse()
                insideFence = true
                fenceBuffer = [line]
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushProse()
            } else {
                buffer.append(line)
            }
        }

        // Unterminated fence — keep it whole anyway rather than leaking it into prose.
        if insideFence && !fenceBuffer.isEmpty {
            blocks.append(Block(text: fenceBuffer.joined(separator: "\n"), isCodeFence: true))
        }
        flushProse()
        return blocks
    }

    static func splitBySentences(_ text: String, maxCharacters: Int) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { substring, _, _, _ in
            if let substring { sentences.append(substring) }
        }
        if sentences.isEmpty { sentences = [text] }

        var out: [String] = []
        var current = ""
        for sentence in sentences {
            if !current.isEmpty && current.count + sentence.count + 1 > maxCharacters {
                out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            if !current.isEmpty { current += " " }
            current += sentence
        }
        if !current.isEmpty { out.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out
    }
}

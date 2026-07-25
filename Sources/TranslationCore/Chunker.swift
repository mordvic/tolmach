// Sources/TranslationCore/Chunker.swift
import Foundation

public struct Chunk: Sendable, Equatable {
    public let index: Int
    public let text: String
    public let containsCodeFence: Bool
}

public enum Chunker {
    struct Block { let text: String; let isCodeFence: Bool }

    public static func chunk(_ text: String, maxCharacters: Int) -> [Chunk] {
        let blocks = blocks(in: text)
        var chunks: [Chunk] = []
        var current = ""
        var currentHasFence = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            chunks.append(Chunk(index: chunks.count, text: trimmed, containsCodeFence: currentHasFence))
            current = ""; currentHasFence = false
        }

        for block in blocks {
            let pieces: [Block] = (block.text.count > maxCharacters && !block.isCodeFence)
                ? splitBySentences(block.text, maxCharacters: maxCharacters).map { Block(text: $0, isCodeFence: false) }
                : [block]
            for piece in pieces {
                if !current.isEmpty && current.count + piece.text.count + 2 > maxCharacters { flush() }
                if !current.isEmpty { current += "\n\n" }
                current += piece.text
                currentHasFence = currentHasFence || piece.isCodeFence
            }
        }
        flush()
        return chunks
    }

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
            let isMarker = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if insideFence {
                fenceBuffer.append(line)
                if isMarker {
                    blocks.append(Block(text: fenceBuffer.joined(separator: "\n"), isCodeFence: true))
                    fenceBuffer = []; insideFence = false
                }
                continue
            }
            if isMarker { flushProse(); insideFence = true; fenceBuffer = [line]; continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushProse() } else { buffer.append(line) }
        }
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
                out.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = ""
            }
            if !current.isEmpty { current += " " }
            current += sentence
        }
        if !current.isEmpty { out.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out
    }
}

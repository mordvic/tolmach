import Foundation
import TranslationCore

/// One corpus text: `<name>.txt`, and `<name>.meta.json` beside it when there is one.
public struct CorpusItem: Sendable, Equatable {
    public let name: String
    public let language: Language
    public let text: String
    public let meta: ItemMeta?

    public init(name: String, language: Language, text: String, meta: ItemMeta?) {
        self.name = name; self.language = language; self.text = text; self.meta = meta
    }

    public var facts: [ItemMeta.Fact] { meta?.facts ?? [] }
}

public enum CorpusLoader {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(path: String, reason: String)
        case languageUnknown(item: String)
        case languageDisagrees(item: String, name: String, sidecar: String)
        case empty(path: String)

        public var description: String {
            switch self {
            case let .unreadable(path, reason): "cannot read \(path) — \(reason)"
            case let .languageUnknown(item):
                "\(item): no sidecar and no ru-/en- style name prefix says what language it is in"
            case let .languageDisagrees(item, name, sidecar):
                "\(item): the file name says \(name), its sidecar says \(sidecar)"
            case let .empty(path): "no .txt files in \(path)"
            }
        }
    }

    /// Every `*.txt` in `directory`, by name. The language is **stated, never detected** — by
    /// the sidecar, or by the `ru-`/`en-` prefix `docs/proofreading-gate` and its three scripts
    /// already use — because a detector's guess would put the run's language column on the
    /// same footing as the replies it is there to check.
    public static func load(directory: URL) throws -> [CorpusItem] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw Failure.unreadable(path: directory.path, reason: error.localizedDescription)
        }
        let texts = names.filter { $0.hasSuffix(".txt") }.sorted()
        guard !texts.isEmpty else { throw Failure.empty(path: directory.path) }

        return try texts.map { file in
            let name = String(file.dropLast(".txt".count))
            let url = directory.appendingPathComponent(file)
            let text: String
            do { text = try String(contentsOf: url, encoding: .utf8) } catch {
                throw Failure.unreadable(path: url.path, reason: error.localizedDescription)
            }
            let sidecar = directory.appendingPathComponent("\(name).meta.json")
            var meta: ItemMeta?
            if FileManager.default.fileExists(atPath: sidecar.path) {
                do { meta = try JSONDecoder().decode(ItemMeta.self, from: Data(contentsOf: sidecar)) } catch {
                    throw Failure.unreadable(path: sidecar.path, reason: "\(error)")
                }
            }
            let prefix = name.split(separator: "-").first.map(String.init).flatMap(Language.init(rawValue:))
            let stated = meta.flatMap { Language(rawValue: $0.language) }
            if let meta, let prefix, stated != prefix {
                throw Failure.languageDisagrees(item: name, name: prefix.rawValue, sidecar: meta.language)
            }
            guard let language = stated ?? prefix else { throw Failure.languageUnknown(item: name) }
            return CorpusItem(name: name, language: language, text: text, meta: meta)
        }
    }

    /// FNV-1a over every item's name and bytes, in order — enough to say «this is not the
    /// corpus that run was taken on», which is all it is for. Not a cryptographic hash, and
    /// deliberately not CryptoKit: the framework list is closed (`docs/adr/0007`).
    public static func hash(of items: [CorpusItem]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func feed(_ string: String) {
            for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            hash = (hash ^ 0xff) &* 0x0000_0100_0000_01b3
        }
        for item in items {
            feed(item.name); feed(item.text)
            for fact in item.facts { feed(fact.id); fact.anyOf.forEach(feed) }
        }
        return String(hash, radix: 16)
    }
}

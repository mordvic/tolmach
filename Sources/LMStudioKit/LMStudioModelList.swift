// Sources/LMStudioKit/LMStudioModelList.swift
import Foundation

public struct LMStudioModel: Sendable, Equatable {
    public let key: String
    public let displayName: String
    public let sizeBytes: Int64
    public let format: String?
    /// The ids of this model's loaded instances, which is what `LMStudioClient.unload` needs.
    ///
    /// Carried rather than flattened to a Bool, and that is a correction: with only `isLoaded`
    /// there was no way for a caller to name what it wanted unloaded. They happened to equal
    /// the model key on every instance observed on 2026-08-21 — which is exactly the sort of
    /// coincidence this project does not build on.
    public let loadedInstanceIDs: [String]
    public let reasoningOptions: [String]?

    public var isLoaded: Bool { !loadedInstanceIDs.isEmpty }

    public init(key: String, displayName: String, sizeBytes: Int64, format: String?,
                loadedInstanceIDs: [String], reasoningOptions: [String]?) {
        self.key = key
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.format = format
        self.loadedInstanceIDs = loadedInstanceIDs
        self.reasoningOptions = reasoningOptions
    }
}

/// Reads `GET /api/v1/models`, which answers what `/api/tags` and `/api/ps` answer *together*
/// on Ollama: what is installed, how big it is, and what is loaded right now.
///
/// **Embedding models are dropped here**, on the strength of the `type` field. Ollama's
/// `/api/tags` cannot distinguish them and this project has always listed whatever it was
/// given; this server can, and offering an embedding model in a translation-model picker is a
/// defect with a confusing failure at the far end of it.
///
/// The test is «is it an embedding», not «is it an LLM», and the difference is the failure mode:
/// the documented values are `llm` and `embedding`, but a value this code has never seen should
/// reach the picker and be tried rather than vanish from it silently.
public enum LMStudioModelList {
    public static func parse(_ data: Data) throws -> [LMStudioModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["models"] as? [[String: Any]] else {
            throw LMStudioError.decoding("unexpected /api/v1/models shape")
        }
        return raw.compactMap(model(from:))
    }

    private static func model(from entry: [String: Any]) -> LMStudioModel? {
        guard entry["type"] as? String != "embedding", let key = entry["key"] as? String else { return nil }
        return LMStudioModel(
            key: key,
            displayName: entry["display_name"] as? String ?? key,
            sizeBytes: (entry["size_bytes"] as? NSNumber)?.int64Value ?? 0,
            format: entry["format"] as? String,
            // An instance carries only `id` and `config` — measured 2026-08-21 — so nothing here
            // can say who loaded a model or whether it was loaded on demand. That is why this
            // module offers no «unload everything»: it could not tell whose model it was taking.
            loadedInstanceIDs: ((entry["loaded_instances"] as? [[String: Any]]) ?? [])
                .compactMap { $0["id"] as? String },
            // Nil, not `[]`, when the model reports no capabilities: `ReasoningChoice` treats
            // «not known» as «send nothing», and flattening the two would turn an unknown into
            // a claim.
            reasoningOptions: reasoningOptions(of: entry))
    }

    private static func reasoningOptions(of entry: [String: Any]) -> [String]? {
        guard let capabilities = entry["capabilities"] as? [String: Any],
              let reasoning = capabilities["reasoning"] as? [String: Any] else { return nil }
        return reasoning["allowed_options"] as? [String]
    }
}

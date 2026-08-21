// Tests/LMStudioKitTests/LMStudioModelListTests.swift
import Testing
import Foundation
@testable import LMStudioKit

/// Trimmed from the live `GET /api/v1/models` of 2026-08-21 — same fields, same nesting, four
/// of the five entries this machine reports. `qwen3.5-27b` is here because it is the one that
/// reports **no** `capabilities` object at all, and the embedding model is here because it must
/// not reach a translation-model picker.
private let response = #"""
{"models":[
  {"type":"llm","publisher":"qwen","key":"qwen/qwen3.8-27b","display_name":"Qwen3.8 27B",
   "architecture":"qwen3_5","quantization":{"name":"6bit","bits_per_weight":6},
   "size_bytes":22810000000,"params_string":"27B","loaded_instances":[],
   "max_context_length":262144,"format":"mlx",
   "capabilities":{"vision":false,"trained_for_tool_use":true,
                   "reasoning":{"allowed_options":["off","low","medium","xhigh","on"],"default":"xhigh"}}},
  {"type":"llm","publisher":"openai","key":"openai/gpt-oss-20b","display_name":"GPT-OSS 20B",
   "architecture":"gpt_oss","size_bytes":12100000000,"params_string":"20B",
   "loaded_instances":[{"id":"openai/gpt-oss-20b","config":{"context_length":131072}}],
   "max_context_length":131072,"format":"mlx",
   "capabilities":{"vision":false,"trained_for_tool_use":true,
                   "reasoning":{"allowed_options":["low","medium","high"],"default":"low"}}},
  {"type":"llm","publisher":"","key":"qwen3.5-27b","display_name":"qwen3.5 27B",
   "size_bytes":22800000000,"loaded_instances":[],"format":"mlx"},
  {"type":"embedding","publisher":"","key":"text-embedding-nomic-embed-text-v1.5",
   "display_name":"Nomic Embed","size_bytes":84110000,"loaded_instances":[]}
]}
"""#

@Test func theModelListReportsSizeResidencyAndWhatEachModelAllows() throws {
    let models = try LMStudioModelList.parse(Data(response.utf8))
    #expect(models.map(\.key) == ["qwen/qwen3.8-27b", "openai/gpt-oss-20b", "qwen3.5-27b"],
            "an embedding model must not reach a translation-model picker")
    #expect(models[0].sizeBytes == 22_810_000_000)
    #expect(models[0].isLoaded == false)
    #expect(models[0].loadedInstanceIDs.isEmpty)
    #expect(models[1].isLoaded == true)
    // The id, not just the fact: `unload` takes an instance id, so a list that only answered
    // «loaded» would leave nothing able to name what to unload.
    #expect(models[1].loadedInstanceIDs == ["openai/gpt-oss-20b"])
    #expect(models[1].reasoningOptions == ["low", "medium", "high"])
    // The row that makes the fail-safe reachable: no capabilities object means «not known»,
    // which must survive parsing as nil rather than collapsing to an empty list.
    #expect(models[2].reasoningOptions == nil)
}

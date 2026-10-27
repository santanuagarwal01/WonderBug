import Foundation
import CoreML

@main struct VectorMain {
    static func emit(_ value: [String: Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { fatalError("Usage: vector-eval corpus reranker vocabulary embedder embedding-vocabulary") }
        let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: args[2]))
        let reranker = try WikiMiniLMReranker(modelURL: compiled, vocabularyURL: URL(fileURLWithPath: args[3]))
        let service = try WikiSearchService(databaseURL: URL(fileURLWithPath: args[1]), retrievalMode: .hybridPassages, reranker: reranker)
        let embeddingURL = try await MLModel.compileModel(at: URL(fileURLWithPath: args[4]))
        let embedder = try WikiSentenceEmbedder(modelURL: embeddingURL, vocabularyURL: URL(fileURLWithPath: args[5]))
        let safety = SafetyService()
        while let line = readLine() {
            do {
                guard let data = line.data(using: .utf8), let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let op = request["op"] as? String, let question = request["question"] as? String else {
                    try emit(["error": "invalid request"]); continue
                }
                if op == "safety" {
                    try emit(["blocked": safety.evaluate(question) == .blocked, "bare_followup": safety.isBareFollowUp(question)]); continue
                }
                guard safety.evaluate(question) == .allowed else { try emit(["error": "question blocked"]); continue }
                if op == "identity" {
                    try emit(["embedder": embedder.identity]); continue
                }
                if op == "embed" {
                    let started = Date()
                    let vector = try embedder.embedding(question)
                    let input = embedder.inputs(question)
                    try emit(["embedding": vector, "embedding_ms": Date().timeIntervalSince(started) * 1000,
                        "inputs": ["input_ids": input.ids, "attention_mask": input.mask, "token_type_ids": input.types]])
                    continue
                }
                if op == "pools" {
                    try emit(["pools": try object(await service.experimentPools(question))]); continue
                }
                if op == "prepare", let ids = request["source_ids"] as? [String], ids.count <= 256 {
                    try emit(["passages": try object(await service.experimentPrepare(question, sourceIDs: ids))]); continue
                }
                if op == "score", let raw = request["passages"] as? [[String: Any]], raw.count <= 20 {
                    var records = try JSONDecoder().decode([WikiEvidenceRecord].self, from: JSONSerialization.data(withJSONObject: raw))
                    guard records.allSatisfy({ safety.safePassage($0.text) != nil }) else { try emit(["error": "unsafe passage"]); continue }
                    if records.isEmpty { try emit(["decision": "retrieval_rejected", "candidates": []]); continue }
                    let started = Date()
                    let scores = try reranker.scores(question: question, passages: records.map(\.text))
                    guard scores.count == records.count, scores.allSatisfy(\.isFinite) else { throw WikiRerankerError.missingScore }
                    for i in records.indices { records[i].relevance = scores[i] }
                    let order = records.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
                    let best = records[order[0]]
                    var response: [String: Any] = ["decision": scores[order[0]] >= 4.0 ? "retrieved" : "retrieval_rejected",
                        "candidates": try object(records), "top_score": scores[order[0]], "gate": 4.0,
                        "reranker_identity": reranker.modelIdentity ?? "unknown", "rerank_ms": Date().timeIntervalSince(started) * 1000]
                    if scores[order[0]] >= 4.0 { response["passage"] = best.text; response["title"] = best.title; response["source_ids"] = best.sourceID.map { [$0] } ?? [] }
                    try emit(response); continue
                }
                try emit(["error": "invalid operation or budget exceeded"])
            } catch { try emit(["error": String(describing: error)]) }
        }
    }
}

import Foundation
import CoreML

/// Offline controls around the app's unchanged retrieval implementation.
/// Oracle rewrites come only from an evaluation request, never from bundled app data.
@main struct ConversationMain {
    static func emit(_ value: [String: Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Usage: conversation-eval database model resources") }
        let model = URL(fileURLWithPath: args[2])
        let compiled = model.pathExtension == "mlmodelc" ? model : try await MLModel.compileModel(at: model)
        let reranker = try WikiMiniLMReranker(modelURL: compiled,
            vocabularyURL: URL(fileURLWithPath: args[3]).appendingPathComponent("wiki-minilm-vocab.txt"))
        let service = try WikiSearchService(databaseURL: URL(fileURLWithPath: args[1]),
            retrievalMode: .hybridPassages, reranker: reranker)
        let session = WikiSearchSession(service: service)
        let safety = SafetyService()
        var pending: [String: Bool] = [:]
        while let line = readLine() {
            do {
                guard let data = line.data(using: .utf8),
                      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    try emit(["error": "invalid JSON"]); continue
                }
                if request["op"] as? String == "reset" {
                    await session.reset(); pending = [:]; try emit(["ok": true]); continue
                }
                guard let arm = request["arm"] as? String,
                      ["baseline", "unscoped-original", "unscoped-resolved"].contains(arm),
                      let question = request["question"] as? String else {
                    try emit(["error": "missing valid arm/question"]); continue
                }
                let started = Date()
                var response: [String: Any] = ["arm": arm, "question": question]
                if safety.evaluate(question) == .blocked ||
                    (pending[arm] == true && safety.isBareFollowUp(question)) {
                    pending[arm] = true
                    response["decision"] = "question_blocked"
                    try emit(response); continue
                }
                pending[arm] = false
                var usedQuestion = question
                if arm == "unscoped-resolved" {
                    guard let resolved = request["resolved_question"] as? String, !resolved.isEmpty else {
                        response["decision"] = "oracle_unresolved"
                        try emit(response); continue
                    }
                    usedQuestion = resolved
                    if safety.evaluate(resolved) == .blocked {
                        pending[arm] = true; response["decision"] = "question_blocked"
                        try emit(response); continue
                    }
                }
                response["retrieval_question"] = usedQuestion
                let lookup: WikiLookup
                let trace: WikiRetrievalTrace?
                if arm == "baseline" {
                    let outcome = await session.lookUp(question)
                    lookup = outcome.lookup; trace = outcome.trace
                    response["reused_topic"] = outcome.reusedTopic
                } else {
                    lookup = await service.lookUp(usedQuestion)
                    trace = await service.retrievalTrace()
                }
                response["trace"] = try trace.map { try object($0) }
                switch lookup {
                case .found(let passage):
                    response["decision"] = safety.safePassage(passage.text) == nil ? "passage_blocked" : "retrieved"
                    response["passage"] = passage.text; response["title"] = passage.title
                    response["source_ids"] = passage.sourceIDs
                case .notFound(let miss):
                    response["decision"] = "retrieval_rejected"; response["rejection_reason"] = miss.reason
                }
                response["elapsed_ms"] = Date().timeIntervalSince(started) * 1000
                try emit(response)
            } catch { try emit(["error": String(describing: error)]) }
        }
    }
}

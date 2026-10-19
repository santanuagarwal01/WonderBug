import Foundation
import CoreML

/// JSON-lines interface using the app's actual retrieval, safety, cleanup and grounding code.
@main struct EvaluationMain {
    static func emit(_ value: [String: Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Usage: evaluation database model.mlpackage resources") }
        let modelURL = URL(fileURLWithPath: args[2])
        let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try await MLModel.compileModel(at: modelURL)
        let reranker = try WikiMiniLMReranker(modelURL: compiled,
            vocabularyURL: URL(fileURLWithPath: args[3]).appendingPathComponent("wiki-minilm-vocab.txt"))
        var sessions: [String: WikiSearchSession] = [:]
        for mode in [WikiSearchService.RetrievalMode.legacy, .passages, .directPassages, .hybridPassages, .calibratedPassages] {
            sessions[mode.rawValue] = WikiSearchSession(service: try WikiSearchService(
                databaseURL: URL(fileURLWithPath: args[1]), retrievalMode: mode, reranker: reranker,
                calibratedGate: WikiRelevanceGate.load(URL(fileURLWithPath: args[3]).appendingPathComponent("wiki-relevance-gate.json"))))
        }
        let safety = SafetyService()
        while let line = readLine() {
            do {
                guard let data = line.data(using: .utf8),
                      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    try emit(["error": "invalid JSON request"]); continue
                }
                switch request["op"] as? String {
                case "prompts": try emit(["system": AppPrompts.systemPrompt])
                case "reset":
                    for session in sessions.values { await session.reset() }
                    try emit(["ok": true])
                case "question":
                    let text = request["text"] as? String ?? ""
                    try emit(["blocked": safety.evaluate(text) == .blocked, "bare_follow_up": safety.isBareFollowUp(text)])
                case "lookup":
                    guard let mode = request["mode"] as? String, let session = sessions[mode],
                          let question = request["question"] as? String else {
                        try emit(["error": "missing mode/question"]); continue
                    }
                    let outcome = await session.lookUp(question)
                    var response: [String: Any] = ["mode": mode, "question": question]
                    response["trace"] = try outcome.trace.map { try object($0) }
                    response["reused_topic"] = outcome.reusedTopic
                    switch outcome.lookup {
                    case .found(let passage):
                        response["passage"] = passage.text
                        response["title"] = passage.title
                        response["source_ids"] = passage.sourceIDs
                        response["passage_safe"] = safety.safePassage(passage.text) != nil
                    case .notFound(let miss): response["rejection_reason"] = miss.reason
                    }
                    try emit(response)
                case "passage":
                    try emit(["safe": safety.safePassage(request["text"] as? String ?? "") != nil])
                case "answer":
                    let cleaned = AnswerCleanup.clean(request["raw"] as? String ?? "")
                    let passage = request["passage"] as? String ?? ""
                    try emit(["cleaned": cleaned, "blocked": safety.evaluateAnswer(cleaned) == .blocked,
                              "grounded": WikiSearchService.isGrounded(answer: cleaned, passage: passage),
                              "score": WikiSearchService.groundingScore(answer: cleaned, passage: passage)])
                default: try emit(["error": "unknown operation"])
                }
            } catch { try emit(["error": String(describing: error)]) }
        }
    }
}

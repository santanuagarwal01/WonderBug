import Foundation

/// Opt-in local evaluation records. Never uploaded; disabled unless the debug scheme enables it.
@MainActor enum EvaluationLog {
    private static let runID = UUID().uuidString
    struct Record: Encodable {
        var schemaVersion = 1
        var timestamp = Date()
        var question: String
        var answerModel = "bundled-Qwen3-1.7B-4bit"
        var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        var appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        var retrievalMode = WikiSearchService.configuredMode.rawValue
        var trace: WikiRetrievalTrace?
        var reusedTopic: String?
        var generatedAnswer: String?
        var displayedAnswer: String?
        var decision = "error"
        var elapsedMS: Double = 0
    }
    private struct Envelope: Encodable {
        var runID: String
        var record: Record
    }
    static func append(_ record: Record) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["WONDERBUG_EVALUATION_LOG"] == "1"
            || Bundle.main.object(forInfoDictionaryKey: "WonderBugEvaluationLog") as? String == "1" else { return }
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("Evaluation", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("session-\(runID).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Envelope(runID: runID, record: record))
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
        } catch { DebugLog.section("EVALUATION", "Could not record evaluation: \(error)") }
        #endif
    }
}

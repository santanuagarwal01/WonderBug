import Foundation

/// Evidence traces are evaluation data, not confidence scores or factuality labels.
nonisolated struct WikiEvidenceRecord: Codable, Sendable {
    var sourceID: String?
    var title: String
    var section: String?
    var text: String
    var relevance: Double?
}

nonisolated struct WikiRetrievalTrace: Codable, Sendable {
    var schemaVersion = 1
    var retrievalVersion = "passage-fts-v1"
    var mode: String
    var question: String
    var retrievedSources: [WikiEvidenceRecord] = []
    var candidates: [WikiEvidenceRecord] = []
    var selectedSourceIDs: [String] = []
    var selectedTitle: String?
    var selectedText: String?
    var rejectionReason: String?
    var elapsedMS: Double = 0
    var gateVersion: String?
    var gateThreshold: Double?
    var rerankerIdentity: String?
}

/// A development-calibrated operating point, NOT a probability of factual correctness.
nonisolated struct WikiRelevanceGate: Codable, Sendable {
    var version: String
    var retrievalVersion: String
    var rerankerIdentity: String
    var threshold: Double

    static func load(_ url: URL?) -> WikiRelevanceGate? {
        guard let url, let data = try? Data(contentsOf: url),
              let gate = try? JSONDecoder().decode(Self.self, from: data),
              gate.threshold.isFinite, gate.version == "support-cutoff-v1",
              gate.retrievalVersion == "hybrid-passages-v3" else { return nil }
        return gate
    }
}

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
}

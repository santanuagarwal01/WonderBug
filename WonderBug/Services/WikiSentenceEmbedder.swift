import Foundation
import CoreML

/// Small, independently trained sentence encoder. It does not reuse cross-encoder weights.
nonisolated final class WikiSentenceEmbedder {
    private let model: MLModel
    private let tokenizer: WikiWordPieceTokenizer
    let identity: [String: String]
    init(modelURL: URL, vocabularyURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        identity = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard identity["dimensions"] == "384", identity["sequence_length"] == "256", identity["source_weights_sha256"] != nil else {
            throw WikiRerankerError.unavailable
        }
        tokenizer = try WikiWordPieceTokenizer(vocabularyURL: vocabularyURL)
    }
    func inputs(_ text: String) -> (ids: [Int], mask: [Int], types: [Int]) {
        tokenizer.encodeSentence(text)
    }
    func embedding(_ text: String) throws -> [Float] {
        let encoded = inputs(text)
        func array(_ values: [Int]) throws -> MLMultiArray {
            let result = try MLMultiArray(shape: [1, 256], dataType: .int32)
            for (i, value) in values.enumerated() { result[i] = NSNumber(value: value) }
            return result
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": array(encoded.ids), "attention_mask": array(encoded.mask), "token_type_ids": array(encoded.types)])
        let prediction = try model.prediction(from: input)
        guard let values = prediction.featureValue(for: "embedding")?.multiArrayValue, values.count == 384 else {
            throw WikiRerankerError.missingScore
        }
        let vector = (0..<384).map { values[$0].floatValue }
        guard vector.allSatisfy(\.isFinite) else { throw WikiRerankerError.missingScore }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { throw WikiRerankerError.missingScore }
        return vector.map { $0 / norm }
    }
}

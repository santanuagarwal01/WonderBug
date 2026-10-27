import Foundation
import CoreML

/// Scores question/passage pairs. Higher is more relevant; scores are NOT probabilities.
nonisolated protocol WikiPassageReranking: AnyObject {
    func scores(question: String, passages: [String]) throws -> [Double]
    var modelIdentity: String? { get }
}

nonisolated extension WikiPassageReranking { var modelIdentity: String? { nil } }

nonisolated enum WikiRerankerError: Error {
    case invalidVocabulary, missingScore, unavailable
}

/// BERT uncased WordPiece preprocessing for the pinned MiniLM model. Kept independent of
/// Qwen's tokenizer: the two models do not share a vocabulary or special-token conventions.
nonisolated struct WikiWordPieceTokenizer {
    static let sequenceLength = 256
    private let vocabulary: [String: Int]

    init(vocabularyURL: URL) throws {
        let lines = try String(contentsOf: vocabularyURL, encoding: .utf8).components(separatedBy: "\n")
        vocabulary = Dictionary(lines.enumerated().filter { !$0.element.isEmpty }.map { ($0.element, $0.offset) },
                                uniquingKeysWith: { first, _ in first })
        guard vocabulary["[PAD]"] == 0, vocabulary["[UNK]"] == 100,
              vocabulary["[CLS]"] == 101, vocabulary["[SEP]"] == 102 else {
            throw WikiRerankerError.invalidVocabulary
        }
    }

    func encode(question: String, passage: String) -> (ids: [Int], mask: [Int], types: [Int]) {
        let query = Array(tokens(question).prefix(48))
        let body = Array(tokens(passage).prefix(Self.sequenceLength - query.count - 3))
        let ids = [101] + query + [102] + body + [102]
        let padding = Array(repeating: 0, count: Self.sequenceLength - ids.count)
        return (ids + padding, Array(repeating: 1, count: ids.count) + padding,
                Array(repeating: 0, count: query.count + 2) + Array(repeating: 1, count: body.count + 1) + padding)
    }

    func encodeSentence(_ text: String) -> (ids: [Int], mask: [Int], types: [Int]) {
        let ids = [101] + Array(tokens(text).prefix(254)) + [102]
        let padding = Array(repeating: 0, count: 256 - ids.count)
        return (ids + padding, Array(repeating: 1, count: ids.count) + padding, Array(repeating: 0, count: 256))
    }

    private func tokens(_ text: String) -> [Int] {
        var clean = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0 || value == 0xFFFD { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { clean.append(" "); continue }
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            let chinese = (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
                || (0x20000...0x2A6DF).contains(value) || (0x2A700...0x2B73F).contains(value)
                || (0x2B740...0x2B81F).contains(value) || (0x2B820...0x2CEAF).contains(value)
                || (0xF900...0xFAFF).contains(value) || (0x2F800...0x2FA1F).contains(value)
            if chinese { clean += " \(scalar) " } else { clean.unicodeScalars.append(scalar) }
        }
        let normalized = clean.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { $0.properties.generalCategory != .nonspacingMark }
        var words: [String] = []
        var word = ""
        func flush() { if !word.isEmpty { words.append(word); word = "" } }
        for scalar in normalized {
            let value = scalar.value
            let punctuation = (33...47).contains(value) || (58...64).contains(value)
                || (91...96).contains(value) || (123...126).contains(value)
                || CharacterSet.punctuationCharacters.contains(scalar)
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { flush() }
            else if punctuation { flush(); words.append(String(scalar)) }
            else { word.unicodeScalars.append(scalar) }
        }
        flush()
        return words.flatMap { word -> [Int] in
            let scalars = Array(word.unicodeScalars)
            if scalars.count > 100 { return [100] }
            var result: [Int] = []
            var start = 0
            while start < scalars.count {
                var end = scalars.count
                var match: Int?
                while start < end {
                    let piece = (start > 0 ? "##" : "") + String(String.UnicodeScalarView(scalars[start..<end]))
                    if let id = vocabulary[piece] { match = id; break }
                    end -= 1
                }
                guard let match else { return [100] }
                result.append(match)
                start = end
            }
            return result
        }
    }
}

/// Owned and called serially by WikiSearchService's actor. No network, vector database, or
/// additional runtime package. Model loading is lazy and cached across questions.
nonisolated final class WikiMiniLMReranker: WikiPassageReranking {
    private let modelURL: URL
    private let tokenizer: WikiWordPieceTokenizer
    private var model: MLModel?
    private(set) var modelIdentity: String?

    init(modelURL: URL, vocabularyURL: URL) throws {
        self.modelURL = modelURL
        tokenizer = try WikiWordPieceTokenizer(vocabularyURL: vocabularyURL)
    }

    static func bundled() -> WikiMiniLMReranker? {
        guard let model = Bundle.main.url(forResource: "WikiMiniLM", withExtension: "mlmodelc"),
              let vocabulary = Bundle.main.url(forResource: "wiki-minilm-vocab", withExtension: "txt") else { return nil }
        return try? WikiMiniLMReranker(modelURL: model, vocabularyURL: vocabulary)
    }

    func scores(question: String, passages: [String]) throws -> [Double] {
        if model == nil {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
            if let metadata = model?.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
               let source = metadata["source"], let revision = metadata["revision"] {
                modelIdentity = source + "@" + revision + (metadata["adapted_weights_sha256"].map { ":" + $0 } ?? "")
            }
        }
        guard let model else { throw WikiRerankerError.unavailable }
        return try passages.map { passage in
            let encoded = tokenizer.encode(question: question, passage: passage)
            func array(_ values: [Int]) throws -> MLMultiArray {
                let output = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
                for (index, value) in values.enumerated() { output[index] = NSNumber(value: value) }
                return output
            }
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": array(encoded.ids), "attention_mask": array(encoded.mask),
                "token_type_ids": array(encoded.types)
            ])
            let prediction = try model.prediction(from: input)
            guard let score = prediction.featureValue(for: "score")?.multiArrayValue?[0].doubleValue,
                  score.isFinite else { throw WikiRerankerError.missingScore }
            return score
        }
    }
}

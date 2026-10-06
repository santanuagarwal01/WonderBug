import Foundation
import CoreML

@main struct Probe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Usage: probe database model.mlpackage resources-directory") }
        let resources = URL(fileURLWithPath: args[3])
        let model = try await MLModel.compileModel(at: URL(fileURLWithPath: args[2]))
        let reranker = try WikiMiniLMReranker(modelURL: model,
            vocabularyURL: resources.appendingPathComponent("wiki-minilm-vocab.txt"))
        let service = try WikiSearchService(databaseURL: URL(fileURLWithPath: args[1]), retrievalMode: .passages, reranker: reranker)
        let legacy = try WikiSearchService(databaseURL: URL(fileURLWithPath: args[1]))
        let questions = ["Why do giraffes have long necks?", "What do armadillos eat?", "Why do we get goosebumps?",
            "Why do stars twinkle?", "Why do cats purr?", "What do koalas eat?", "How do elephants communicate?",
            "Do fish have lungs?", "Is a whale a fish?", "Why do leaves change color?", "Why do dogs wag their tails?",
            "What do flibberwumps eat?", "Can ostriches fly?", "What is a volcano?", "How many legs do spiders have?"]
        for question in questions {
            func describe(_ result: WikiLookup) -> String {
                switch result {
                case .notFound(let miss): return "MISS: \(miss.reason)"
                case .found(let passage): return "\(passage.title) § \(passage.section ?? "lead")\n\(passage.text)"
                }
            }
            let baseline = await legacy.lookUp(question)
            let start = Date()
            let result = await service.lookUp(question)
            print("\nQUESTION: \(question)\nLEGACY: \(describe(baseline))\nEXPERIMENT (\(Int(Date().timeIntervalSince(start)*1000)) ms): \(describe(result))")
        }
    }
}

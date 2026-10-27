import Foundation
import CoreML

/// Test-only executable. The build script appends an asset injection hook to a temporary
/// copy of the actual app service; retrieval itself runs unchanged.
@main struct DeviceProbe {
    static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let encoder = try await MLModel.compileModel(at: resources.appendingPathComponent("WikiEmbedder.mlpackage"))
        let model = try await MLModel.compileModel(at: resources.appendingPathComponent("WikiMiniLM.mlpackage"))
        let vocabulary = resources.appendingPathComponent("wiki-minilm-vocab.txt")
        let reranker = try WikiMiniLMReranker(modelURL: model, vocabularyURL: vocabulary)
        let corpus = resources.appendingPathComponent("simplewiki-vector.db")
        let service = try WikiSearchService(databaseURL: corpus, retrievalMode: .sqliteVec, reranker: reranker)
        let session = WikiSearchSession(service: service)
        let assets = WikiVectorIndex.Assets(corpus: corpus,
            index: resources.appendingPathComponent("wiki-vectors-binary.db"), model: encoder,
            vocabulary: vocabulary, manifest: resources.appendingPathComponent("wiki-vector-manifest.json"))
        await service.deviceTestAssets(assets)
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
            let question = request["question"] ?? ""
            if request["op"] == "reset" {
                await session.reset()
                FileHandle.standardOutput.write(Data("{}\n".utf8))
                continue
            }
            if request["op"] == "missing-assets" { await service.deviceTestAssets(nil) }
            if let manifest = request["manifest"] {
                await service.deviceTestAssets(WikiVectorIndex.Assets(corpus: corpus, index: assets.index,
                    model: encoder, vocabulary: vocabulary, manifest: URL(fileURLWithPath: manifest)))
            }
            let result: WikiLookup
            if request["op"] == "session" { result = await session.lookUp(question).lookup }
            else { result = await service.lookUp(question) }
            var output: [String: Any] = [:]
            if let trace = await service.retrievalTrace() {
                output["trace"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trace))
            }
            switch result {
            case .found(let passage): output["decision"] = "retrieved"; output["passage"] = passage.text
            case .notFound(let reason): output["decision"] = "retrieval_rejected"; output["reason"] = reason.reason
            }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
}

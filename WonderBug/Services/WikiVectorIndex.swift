#if canImport(CSQLiteVec)
import Foundation
import CryptoKit
import SQLite3
import CSQLiteVec

nonisolated enum WikiVectorError: Error {
    case incompatibleAssets(String)
    case database(String)
}

/// Read-only, statically linked SQLite-vec. Owned and used only by the search actor.
/// Asset verification and Core ML loading happen once, on the first vector lookup.
nonisolated final class WikiVectorIndex {
    struct Assets {
        let corpus: URL
        let index: URL
        let model: URL
        let vocabulary: URL
        let manifest: URL

        static func bundled(corpus: URL) -> Assets? {
            guard let index = Bundle.main.url(forResource: "wiki-vectors-binary", withExtension: "db"),
                  let model = Bundle.main.url(forResource: "WikiEmbedder", withExtension: "mlmodelc"),
                  let vocabulary = Bundle.main.url(forResource: "wiki-minilm-vocab", withExtension: "txt"),
                  let manifest = Bundle.main.url(forResource: "wiki-vector-manifest", withExtension: "json") else { return nil }
            return Assets(corpus: corpus, index: index, model: model, vocabulary: vocabulary, manifest: manifest)
        }
    }

    struct Manifest: Decodable {
        let corpusSHA256: String
        let indexSHA256: String
        let vocabularySHA256: String
        let encoderWeightsSHA256: String
        let encoderRevision: String
        let encoderSource: String
        let dimensions: Int
        let passageCount: Int
    }

    let manifest: Manifest
    private let database: OpaquePointer
    private let embedder: WikiSentenceEmbedder

    static func sha256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    init(assets: Assets) throws {
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: assets.manifest))
        guard manifest.dimensions == 384,
              try Self.sha256(assets.corpus) == manifest.corpusSHA256,
              try Self.sha256(assets.index) == manifest.indexSHA256,
              try Self.sha256(assets.vocabulary) == manifest.vocabularySHA256 else {
            throw WikiVectorError.incompatibleAssets("corpus/index/vocabulary hash mismatch")
        }
        embedder = try WikiSentenceEmbedder(modelURL: assets.model, vocabularyURL: assets.vocabulary)
        guard embedder.identity["source_weights_sha256"] == manifest.encoderWeightsSHA256,
              embedder.identity["revision"] == manifest.encoderRevision,
              embedder.identity["source"] == manifest.encoderSource else {
            throw WikiVectorError.incompatibleAssets("encoder identity mismatch")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(assets.index.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw WikiVectorError.database("cannot open vector index")
        }
        do {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_vec_init(handle, &message, nil)
            defer { sqlite3_free(message) }
            guard result == SQLITE_OK else { throw WikiVectorError.database("SQLite-vec registration failed") }
            guard try Self.scalar(handle, "SELECT vec_version()") == "v0.1.6",
                  try Self.scalar(handle, "SELECT value FROM metadata WHERE key='complete'") == "true",
                  try Self.scalar(handle, "SELECT value FROM metadata WHERE key='representation'") == "binary",
                  try Self.scalar(handle, "SELECT count(*) FROM vectors_binary") == String(manifest.passageCount) else {
                throw WikiVectorError.incompatibleAssets("incomplete or incompatible binary index")
            }
            let identityText = try Self.scalar(handle, "SELECT value FROM metadata WHERE key='identity'")
            let identity = try JSONSerialization.jsonObject(with: Data(identityText.utf8)) as? [String: Any]
            let encoder = identity?["embedder"] as? [String: Any]
            guard identity?["corpus_sha256"] as? String == manifest.corpusSHA256,
                  encoder?["weights_sha256"] as? String == manifest.encoderWeightsSHA256,
                  encoder?["revision"] as? String == manifest.encoderRevision,
                  encoder?["dimensions"] as? Int == 384 else {
                throw WikiVectorError.incompatibleAssets("index metadata mismatch")
            }
        } catch { sqlite3_close(handle); throw error }
        database = handle
    }

    deinit { sqlite3_close(database) }

    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WikiVectorError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw WikiVectorError.database("missing metadata")
        }
        return String(cString: text)
    }

    func neighbors(_ question: String) throws -> (hits: [(id: Int64, distance: Double)], embeddingMS: Double, searchMS: Double) {
        let start = Date()
        let vector = try embedder.embedding(question)
        let embeddingMS = Date().timeIntervalSince(start) * 1000
        let searchStart = Date()
        var statement: OpaquePointer?
        let sql = "SELECT rowid,distance FROM vectors_binary WHERE embedding MATCH vec_quantize_binary(?) AND k=48 ORDER BY distance"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WikiVectorError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = vector.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        guard bound == SQLITE_OK else { throw WikiVectorError.database("vector binding failed") }
        var hits: [(id: Int64, distance: Double)] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            hits.append((sqlite3_column_int64(statement, 0), sqlite3_column_double(statement, 1)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw WikiVectorError.database(String(cString: sqlite3_errmsg(database))) }
        hits.sort { $0.distance == $1.distance ? $0.id < $1.id : $0.distance < $1.distance }
        return (hits, embeddingMS, Date().timeIntervalSince(searchStart) * 1000)
    }
}
#endif

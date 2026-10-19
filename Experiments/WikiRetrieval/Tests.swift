import Foundation
import SQLite3

final class RecordingReranker: WikiPassageReranking {
    var passages: [String] = []
    var question = ""
    var score: (String) -> Double = { _ in -10 }
    var malformed = false
    var modelIdentity: String? = "fixture-reranker"
    func scores(question: String, passages: [String]) throws -> [Double] {
        self.question = question
        self.passages = passages
        return malformed ? [.nan] : passages.map(score)
    }
}

@main struct Tests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func found(_ result: WikiLookup, containing text: String) -> Bool {
        if case .found(let passage) = result { return passage.text.contains(text) }
        return false
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("fixture.db")
        var database: OpaquePointer?
        require(sqlite3_open(databaseURL.path, &database) == SQLITE_OK, "create fixture database")
        let sql = """
        CREATE TABLE articles(id INTEGER PRIMARY KEY, title TEXT, lead TEXT);
        CREATE TABLE redirects(title_lower TEXT PRIMARY KEY, target TEXT);
        CREATE TABLE paragraphs(article INTEGER, ord INTEGER, section TEXT, text TEXT);
        CREATE INDEX paragraph_article ON paragraphs(article, ord);
        CREATE VIRTUAL TABLE fts USING fts5(title, lead, content='articles', content_rowid='id', tokenize='porter unicode61', detail='none');
        INSERT INTO articles VALUES (1,'Giraffe','Giraffes are mammals that live in Africa.');
        INSERT INTO articles VALUES (2,'Neck','The neck connects the head and body. Some necks are long.');
        INSERT INTO articles VALUES (3,'Koala','Koalas live in Australia.');
        INSERT INTO articles VALUES (4,'Goosebumps','Goosebumps is a book series.');
        INSERT INTO articles VALUES (5,'Goose bumps','Goose bumps happen when tiny muscles pull body hairs upright in cold weather.');
        INSERT INTO articles VALUES (6,'Isle of Man','The Isle of Man is an island in the Irish Sea.');
        INSERT INTO articles VALUES (7,'Arachnid','Arachnids are eight-legged animals.');
        INSERT INTO paragraphs VALUES (7,0,'Physiology','They live on land. They have internal respiratory surfaces. One kind is a book lung. It is used for gas exchange with air.');
        INSERT INTO paragraphs VALUES (1,0,'Appearance','Giraffes have long necks. Their coats have spots.');
        INSERT INTO paragraphs VALUES (1,1,'Feeding','Giraffes use their long necks to reach leaves in tall trees. They eat leaves.');
        INSERT INTO paragraphs VALUES (3,0,'Food','Koalas eat eucalyptus leaves.');
        INSERT INTO paragraphs VALUES (3,1,'Movement','Koalas sometimes florpulate while climbing.');
        INSERT INTO paragraphs VALUES (3,2,'Unsafe fixture','Koalas eat leaves. Murder is mentioned in this deliberately unsafe fixture.');
        INSERT INTO fts(fts) VALUES ('rebuild');
        """
        require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "populate fixture database")
        sqlite3_close(database)
        let reranker = RecordingReranker()
        let service = try WikiSearchService(databaseURL: databaseURL, retrievalMode: .passages, reranker: reranker)
        let legacy = try WikiSearchService(databaseURL: databaseURL)

        reranker.score = { $0.contains("reach leaves") ? 8 : -10 }
        let neck = await service.lookUp("Why do giraffes have long necks?")
        require(found(neck, containing: "reach leaves"), "body evidence must survive low lead coverage")
        require(reranker.passages.contains { $0.hasPrefix("Neck:") }, "more than one candidate article reaches reranker")
        require(reranker.passages.count <= 20, "bounded reranker calls")
        if case .found = await legacy.lookUp("Why do giraffes have long necks?") {
            fatalError("fixture should expose legacy lead-coverage rejection")
        }
        reranker.score = { $0.contains("florpulate") ? 8 : -10 }
        require(found(await service.lookUp("Do koalas florpulate?"), containing: "florpulate"),
                "a word absent from the lead index may exist in the body")
        let invented = await service.lookUp("What do flibberwumps eat?")
        if case .found = invented { fatalError("unknown subject must not become an unrelated diet answer") }
        reranker.score = { $0.hasPrefix("Goose bumps:") ? 8 : -10 }
        require(found(await service.lookUp("Why do we get goosebumps?"), containing: "tiny muscles"),
                "joined title variants must compete with exact titles")
        reranker.score = { $0.hasPrefix("Isle of Man:") ? 8 : -10 }
        require(found(await service.lookUp("What is the Isle of Man?"), containing: "Irish Sea"),
                "title phrases containing stop words must survive")
        reranker.score = { _ in -10 }
        if case .found = await service.lookUp("What do koalas eat?") { fatalError("low relevance must abstain") }
        reranker.malformed = true
        if case .notFound(.rerankerUnavailable) = await service.lookUp("What do koalas eat?") {} else {
            fatalError("malformed model output must fail closed")
        }
        reranker.malformed = false
        reranker.score = { $0.contains("eucalyptus") ? 8 : -10 }
        let session = WikiSearchSession(service: service)
        _ = await session.lookUp("What do koalas eat?")
        require(reranker.passages.allSatisfy { !$0.contains("Murder") }, "unsafe windows must not reach the model")
        let followup = await session.lookUp("Why do they eat leaves?")
        require(followup.reusedTopic == "Koala", "follow-up retains topic")
        require(reranker.question.hasPrefix("Current question: Why do they eat leaves?"), "latest question must survive tokenizer truncation")
        require(reranker.question.contains("Previous question: What do koalas eat?"), "rerank follow-up with previous question")
        require(reranker.passages.allSatisfy { $0.hasPrefix("Koala:") }, "follow-up does not leak another topic")
        await session.reset()
        if case .notFound(.noTopicToReferTo) = await session.lookUp("Can they fly?").lookup {} else {
            fatalError("reset must clear pronoun context")
        }
        let unavailable = try WikiSearchService(databaseURL: databaseURL, retrievalMode: .passages)
        if case .notFound(.rerankerUnavailable) = await unavailable.lookUp("What do koalas eat?") {} else {
            fatalError("missing model must be explicit")
        }

        if CommandLine.arguments.count >= 4 {
            let directURL = directory.appendingPathComponent("direct.db")
            let builder = Process()
            builder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            builder.arguments = [CommandLine.arguments[3], databaseURL.path, directURL.path]
            try builder.run(); builder.waitUntilExit()
            require(builder.terminationStatus == 0, "real index builder must succeed")
            let direct = try WikiSearchService(databaseURL: directURL, retrievalMode: .directPassages, reranker: reranker)
            reranker.score = { $0.contains("gas exchange") ? 8 : -10 }
            let lungs = await direct.lookUp("What are book lungs?")
            require(found(lungs, containing: "gas exchange"), "body-only term must retrieve an unnamed article and preserve the final explanation")
            if case .found(let p) = lungs { require(p.sourceIDs == ["a:7:p:0"], "stable paragraph source ID") }
            let trace = await direct.retrievalTrace()
            require(trace?.retrievedSources.contains { $0.sourceID == "a:7:p:0" } == true, "capture initial FTS candidates")
            require(trace?.candidates.count ?? 100 <= 20, "bounded direct inference")
            reranker.score = { _ in -10 }
            _ = await direct.lookUp("What are book lungs?")
            let rejection = await direct.retrievalTrace()
            require(rejection?.rejectionReason?.contains("low relevance") == true, "retain reason below cutoff")
            require(rejection?.candidates.isEmpty == false, "retain evidence even when gate rejects it")
            let missingIndex = try WikiSearchService(databaseURL: databaseURL, retrievalMode: .directPassages, reranker: reranker)
            if case .notFound(.passageIndexUnavailable) = await missingIndex.lookUp("What are book lungs?") {} else {
                fatalError("old database must fail explicitly in direct mode")
            }
            reranker.malformed = true
            if case .notFound(.rerankerUnavailable) = await direct.lookUp("What are book lungs?") {} else {
                fatalError("direct mode must reject invalid model output")
            }
            reranker.malformed = false
            _ = await direct.lookUp("What is 'lung' OR DROP TABLE articles?")
            reranker.score = { $0.contains("gas exchange") ? 8 : -10 }
            require(found(await direct.lookUp("What are book lungs?"), containing: "gas exchange"), "query punctuation cannot mutate the database")
            let hybrid = try WikiSearchService(databaseURL: directURL, retrievalMode: .hybridPassages, reranker: reranker)
            require(found(await hybrid.lookUp("What are book lungs?"), containing: "gas exchange"), "hybrid must retain body-only evidence")
            reranker.score = { $0.contains("eucalyptus") ? 3.9 : -10 }
            if case .notFound(.lowRelevance) = await hybrid.lookUp("What do koalas eat?") {} else { fatalError("baseline hybrid keeps its original cutoff") }
            let gate = WikiRelevanceGate(version: "support-cutoff-v1", retrievalVersion: "hybrid-passages-v3",
                                        rerankerIdentity: "fixture-reranker", threshold: 3.8)
            let calibrated = try WikiSearchService(databaseURL: directURL, retrievalMode: .calibratedPassages,
                                                   reranker: reranker, calibratedGate: gate)
            require(found(await calibrated.lookUp("What do koalas eat?"), containing: "eucalyptus"), "calibrated operating point must be applied")
            let calibratedTrace = await calibrated.retrievalTrace()
            require(calibratedTrace?.gateThreshold == 3.8 && calibratedTrace?.rerankerIdentity == "fixture-reranker", "log the applied gate and model")
            require((calibratedTrace?.candidates.count ?? 100) <= 20, "combined search cannot exceed twenty model calls")
            require(Set(reranker.passages).count == reranker.passages.count, "no identical reranker inputs")
            reranker.score = { $0.contains("eucalyptus") ? 3.8 : -10 }
            require(found(await calibrated.lookUp("What do koalas eat?"), containing: "eucalyptus"), "inclusive cutoff boundary")
            reranker.modelIdentity = "different-model"
            if case .notFound(.calibrationUnavailable) = await calibrated.lookUp("What do koalas eat?") {} else { fatalError("model-specific calibration must reject a different model") }
            reranker.modelIdentity = "fixture-reranker"
            let uncalibrated = try WikiSearchService(databaseURL: directURL, retrievalMode: .calibratedPassages, reranker: reranker)
            if case .notFound(.calibrationUnavailable) = await uncalibrated.lookUp("What do koalas eat?") {} else { fatalError("missing calibration must be explicit") }
            reranker.malformed = true
            if case .notFound(.rerankerUnavailable) = await hybrid.lookUp("What do koalas eat?") {} else { fatalError("hybrid fails closed on malformed scores") }
            reranker.malformed = false
            reranker.score = { $0.contains("eucalyptus") ? 8 : -10 }
            let hybridSession = WikiSearchSession(service: hybrid)
            _ = await hybridSession.lookUp("What do koalas eat?")
            _ = await hybridSession.lookUp("Why do they eat leaves?")
            require(reranker.passages.allSatisfy { $0.hasPrefix("Koala:") }, "hybrid follow-up retains source scope")
            require(reranker.question.contains("Previous question:"), "hybrid follow-up keeps reranker context")
            print("PASS: hybrid body access, deduplication, budget, calibration boundaries, model mismatch and follow-up scope")
            print("PASS: direct body FTS, complete context, stable provenance, diagnostics, missing index and bounded inference")
        }

        if CommandLine.arguments.count >= 3 {
            struct Fixture: Decodable {
                let question: String
                let passage: String
                let inputs: [String: [Int]]
            }
            let tokenizer = try WikiWordPieceTokenizer(vocabularyURL: URL(fileURLWithPath: CommandLine.arguments[1]))
            let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            for fixture in fixtures {
                let actual = tokenizer.encode(question: fixture.question, passage: fixture.passage)
                require(actual.ids == fixture.inputs["input_ids"], "token ids must match Hugging Face: \(fixture.question)")
                require(actual.mask == fixture.inputs["attention_mask"], "attention mask parity")
                require(actual.types == fixture.inputs["token_type_ids"], "segment ids parity")
            }
            print("PASS: \(fixtures.count) tokenizer parity fixtures")
        }
        print("PASS: retrieval, candidate diversity, unknown constraints, follow-ups, model failure and legacy checks")
    }
}

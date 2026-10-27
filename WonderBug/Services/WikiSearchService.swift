//
//  WikiSearchService.swift
//  WonderBug
//

import Foundation
import SQLite3

/// The text a question is answered from: the article's opening trimmed to the sentences that
/// answer it, or one body paragraph of the article when that answers it better.
struct WikiPassage {
    /// The article's row id, which a follow-up needs to read the rest of its paragraphs.
    let id: Int64
    let title: String
    /// The article's whole stored opening — kept so a follow-up question can reuse this article.
    let lead: String
    /// The sentences handed to the answer model.
    let text: String
    /// Lexical coverage (lead in legacy mode, selected window in the experiment).
    /// Not a calibrated confidence score. Nil for legacy follow-ups.
    let coverage: Double?
    /// The heading of the body section the passage came from; nil when it came from the opening.
    let section: String?
    let runnersUp: [(title: String, score: Double)]
    var sourceIDs: [String] = []
}

/// Why the search has no passage. The child always gets "I don't know yet"; the reason is for the
/// debug log and the evaluation reports.
enum WikiMiss {
    /// The experimental model could not be loaded or produced invalid scores.
    case vectorUnavailable
    case passageIndexUnavailable
    case rerankerUnavailable
    case calibrationUnavailable
    /// A raw model relevance score below the experiment cutoff.
    case lowRelevance(Double, title: String)
    /// The question is nothing but stop words.
    case noContentWords
    /// A word that appears in no article at all — an invented thing, or a typo.
    case unknownWord(String)
    /// Full-text search returned nothing.
    case noMatchingArticle
    /// The best article covers too little of the question ("Animal" for "the biggest animal").
    case lowCoverage(Double, title: String)
    /// A follow-up whose reused article never mentions what was asked ("fly" in "Frog").
    case articleLacksWords([String], title: String)
    /// "Can they fly?" as the first question of a conversation.
    case noTopicToReferTo

    nonisolated var reason: String {
        switch self {
        case .vectorUnavailable: return "SQLite-vec assets unavailable, incompatible, or query failed"
        case .passageIndexUnavailable: return "direct passage index unavailable or incompatible"
        case .rerankerUnavailable: return "reranker model unavailable"
        case .calibrationUnavailable: return "gate calibration missing or incompatible with retrieval/model"
        case .lowRelevance(let score, let title): return String(format: "low relevance %.2f on \"%@\"", score, title)
        case .noContentWords: return "no content words"
        case .unknownWord(let word): return "unknown word \"\(word)\""
        case .noMatchingArticle: return "no matching article"
        case .lowCoverage(let coverage, let title):
            return String(format: "low coverage %.2f on \"%@\"", coverage, title)
        case .articleLacksWords(let words, let title):
            return "previous article \"\(title)\" never mentions [\(words.map { "'\($0)'" }.joined(separator: ", "))]"
        case .noTopicToReferTo: return "\"they/it\" question with no earlier topic to refer to"
        }
    }
}

/// Either a passage to answer from, or the reason there is none.
enum WikiLookup {
    case found(WikiPassage)
    case notFound(WikiMiss)
}

enum WikiSearchError: Error {
    case cannotOpenDatabase(String)
}

/// Searches the bundled Simple English Wikipedia index for a passage that answers a question.
///
/// The legacy mode preserves the Python reference. The passage experiment shortlists body
/// windows across articles and reranks them with a bundled MiniLM model. SQLite FTS5 uses
/// detail=none, so queries combine single-word terms rather than phrase/NEAR searches.
/// All database and synchronous reranker work stays on this actor, off the main thread.
actor WikiSearchService {

    // MARK: - Tuning (mirrors eval_v2.py)

    private static let minimumCoverage = 0.6
    private static let prefixCharacters = 400
    private static let extraSentences = 2
    private static let candidateLimit = 30
    private static let subjectMargin = 2.5
    /// How much of the article's opening rides in front of a body paragraph (see `choosePassage`).
    private static let openingCharacters = 300

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// Question words and other filler that never identify a topic.
    static let stopWords = wordSet("""
    what whats why how who whom whose which where when is are was were be been being am do does did
    done the a an of in on at to for from by with about and or but so it its they them their theirs he
    him his she her hers we us our you your i me my mine this that these those there here any all some
    many much one ones other others can cant could couldnt would wouldnt should will wont have has had
    not no yes like just very really also than then if as into up out tell show picture pictures few
    more
    meant mean called kind type lot lots get got let lets please ever name
    dont doesnt isnt arent didnt wasnt werent hasnt havent hadnt shouldnt aint
    """)

    /// Describing words (verbs, adjectives, and the measurement words of "how tall / long / far"
    /// questions): never the subject of a question, so never a one-word title match.
    static let titleStopWords = wordSet("""
    make makes made eat eats live lives need needs jump jumps swim swims breathe find finds biggest smallest big
    small full good first daily color colour cold hot six eight both land orange blue fish
    tall taller tallest long longer longest far farther old older heavy heavier deep deeper wide wider
    high higher fast faster
    """)

    static let pronouns = wordSet("it its they them their theirs he him his she her one ones this that these those")

    /// Words that always point back at something already discussed.
    static let referringWords = wordSet("they them their theirs he him his she her hers")

    /// An English question puts its subject straight after the auxiliary verb, which is how a
    /// pronoun that points back ("how many teeth do THEY have") is told apart from one that points
    /// at a noun in its own sentence ("why do ELEPHANTS use their trunks").
    static let auxiliaries = wordSet("""
    do does did dont doesnt didnt is are was were isnt arent wasnt werent
    can cant could couldnt will wont would wouldnt should shouldnt has have had hasnt havent hadnt
    """)

    /// Generic synonyms for the verbs and adjectives kids' questions are built around. Used for
    /// coverage and sentence picking only — never for the unknown-word check or title matching.
    private static let synonymGroups = [
        "eat eats ate food feed feeds diet prey predator predators hunt hunts catch catches",
        "make makes made produce produces build builds",
        "live lives living habitat found",
        "big bigger biggest large larger largest size",
        "small smaller smallest tiny little",
        "cold hot heat temperature warm freezing",
        "color colour colors colours colored coloured",
        // "Why does the moon change shape?" — the article calls it a phase.
        "shape shapes phase phases",
    ]

    private static let synonyms: [String: Set<String>] = {
        var table: [String: Set<String>] = [:]
        for group in synonymGroups {
            let stems = Set(group.split(separator: " ").map { stem(String($0)) })
            for stem in stems { table[stem] = stems }
        }
        return table
    }()

    private static let causalStems = Set(["because", "why", "cause", "causes", "caused", "due", "reason"].map(stem))

    /// A superlative question asks for the one thing that is -est, so an article that never uses the
    /// superlative cannot answer it. Unlike other describing words, these are not forgiven when missing.
    private static let superlativeStems = Set(["biggest", "smallest", "tallest", "longest"].map(stem))

    /// Describing words are credited when an article mentions them but never counted against it when
    /// it doesn't: the Whale article not saying "fish" is the answer to "is a whale a fish", not a
    /// reason to give up.
    static let predicateStems = Set(titleStopWords.map(stem)).subtracting(superlativeStems)

    /// Describing words that are a property, which is what a false premise is built from ("is a whale
    /// a fish"). A body paragraph may not win on one of these unless the question asks why: the word
    /// turns up all over an article, and the opening is usually where the premise is settled.
    static let premiseStems = Set(wordSet("""
    full good first daily color colour cold hot six eight both land orange blue fish find finds
    """).map(stem))

    // MARK: - Text handling

    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar == "\u{2019}" || scalar == "'" { continue }
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        for suffix in ["sses", "xes", "ches", "shes", "uses"] where word.hasSuffix(suffix) {
            return String(word.dropLast(2))
        }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }

    static func stems(of text: String) -> Set<String> {
        Set(words(in: text).map(stem))
    }

    private static let sentenceBreak = try! NSRegularExpression(pattern: "(?<=[.!?])\\s+(?=[A-Z0-9\"(])")

    static func sentences(in text: String) -> [String] {
        let full = text as NSString
        var parts: [String] = []
        var start = 0
        sentenceBreak.enumerateMatches(in: text, range: NSRange(location: 0, length: full.length)) { match, _, _ in
            guard let match else { return }
            parts.append(full.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        parts.append(full.substring(from: start))
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Database

    private struct Article {
        let id: Int64
        let title: String
        let lead: String
    }

    private struct QueryTerm {
        let stem: String
        let weight: Double
        let senses: Set<String>
    }

    private let calibratedGate: WikiRelevanceGate?
    private let retrievalMode: RetrievalMode
    private var usesHybridRetrieval: Bool { retrievalMode == .hybridPassages || retrievalMode == .calibratedPassages || retrievalMode == .sqliteVec }
    private let reranker: WikiPassageReranking?
    #if canImport(CSQLiteVec)
    private var vectorIndex: WikiVectorIndex?
    private var vectorAssets: WikiVectorIndex.Assets?
    #endif
    private let database: OpaquePointer
    private let articleCount: Double
    private let hasPassageIndex: Bool
    private var trace: WikiRetrievalTrace?

    func retrievalTrace() -> WikiRetrievalTrace? { trace }
    private var documentFrequencies: [String: Int] = [:]
    private static let transientText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL, retrievalMode: RetrievalMode = .legacy, reranker: WikiPassageReranking? = nil, calibratedGate: WikiRelevanceGate? = nil) throws {
        self.calibratedGate = calibratedGate
        self.retrievalMode = retrievalMode
        self.reranker = reranker
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            throw WikiSearchError.cannotOpenDatabase(databaseURL.path)
        }
        database = handle
        var count = 0.0
        WikiSearchService.step(handle, "SELECT COUNT(*) FROM articles", []) { statement in
            count = Double(sqlite3_column_int64(statement, 0))
        }
        articleCount = count
        var indexVersion = ""
        WikiSearchService.step(handle, "SELECT value FROM passage_index_metadata WHERE key='schema_version'", []) {
            indexVersion = WikiSearchService.text($0, 0)
        }
        hasPassageIndex = indexVersion == "1"
        #if canImport(CSQLiteVec)
        if retrievalMode == .sqliteVec { vectorAssets = WikiVectorIndex.Assets.bundled(corpus: databaseURL) }
        #endif
    }

    deinit {
        sqlite3_close(database)
    }

    /// The index shipped inside the app. Xcode's synchronized groups flatten resource folders, so
    /// the file sits at the top level of the bundle rather than under Resources/.
    static func bundled() -> WikiSearchService? {
        let mode = configuredMode
        let name = mode == .sqliteVec ? "simplewiki-vector" : "simplewiki"
        guard let url = Bundle.main.url(forResource: name, withExtension: "db") else { return nil }
        return try? WikiSearchService(databaseURL: url, retrievalMode: mode,
                                     reranker: mode == .legacy ? nil : WikiMiniLMReranker.bundled(),
                                     calibratedGate: WikiRelevanceGate.load(Bundle.main.url(forResource: "wiki-relevance-gate", withExtension: "json")))
    }

    nonisolated static var configuredMode: RetrievalMode {
        #if SQLITE_VEC_EXPERIMENT
        // A home-screen launch must retain the experiment even without Xcode's environment.
        return .sqliteVec
        #else
        let configured = ProcessInfo.processInfo.environment["WONDERBUG_WIKI_RETRIEVAL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "WonderBugRetrievalMode") as? String ?? "legacy"
        return RetrievalMode(rawValue: configured) ?? .legacy
        #endif
    }

    private static func step(_ database: OpaquePointer, _ sql: String, _ bindings: [String],
                             each: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transientText)
        }
        while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
    }

    private func step(_ sql: String, _ bindings: [String] = [], each: (OpaquePointer) -> Void) {
        WikiSearchService.step(database, sql, bindings, each: each)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// The first article row the query returns.
    private func firstArticle(_ sql: String, _ bindings: [String] = []) -> Article? {
        var found: Article?
        step(sql, bindings) { statement in
            if found == nil {
                found = Article(id: sqlite3_column_int64(statement, 0),
                                title: WikiSearchService.text(statement, 1),
                                lead: WikiSearchService.text(statement, 2))
            }
        }
        return found
    }

    private func article(id: Int64) -> Article? {
        firstArticle("SELECT id, title, lead FROM articles WHERE id = \(id)")
    }

    private func article(titled title: String) -> Article? {
        firstArticle("SELECT id, title, lead FROM articles WHERE title = ? COLLATE NOCASE", [title])
    }

    /// The article's body paragraphs in document order. Not in the full-text index: they are read
    /// for the shortlisted articles (or the single chosen article in legacy mode).
    private func paragraphs(of id: Int64) -> [(section: String, text: String, ordinal: Int)] {
        var found: [(section: String, text: String, ordinal: Int)] = []
        step("SELECT section, text, ord FROM paragraphs WHERE article = \(id) ORDER BY ord") { statement in
            found.append((WikiSearchService.text(statement, 0), WikiSearchService.text(statement, 1), Int(sqlite3_column_int64(statement, 2))))
        }
        return found
    }

    private func documentFrequency(_ term: String) -> Int {
        if let cached = documentFrequencies[term] { return cached }
        var count = 0
        step("SELECT COUNT(*) FROM fts WHERE fts MATCH ?", ["\"\(term)\""]) { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        documentFrequencies[term] = count
        return count
    }

    private func inverseDocumentFrequency(_ term: String) -> Double {
        log((articleCount + 1) / (Double(documentFrequency(term)) + 1))
    }

    /// The word itself, then the singular forms to fall back on.
    static func singulars(_ word: String) -> [String] {
        var forms = [word]
        if word.hasSuffix("ies") { forms.append(String(word.dropLast(3)) + "y") }
        if word.hasSuffix("es") { forms.append(String(word.dropLast(2))) }
        if word.hasSuffix("s") { forms.append(String(word.dropLast())) }
        return forms
    }

    /// The form of a word the index holds. FTS5 does not fold "mantises" to "mantis", so without this
    /// an ordinary plural looks like an invented word.
    private func indexForm(_ word: String) -> String {
        if documentFrequency(word) > 0 { return word }
        return WikiSearchService.singulars(word).dropFirst().first { documentFrequency($0) > 0 } ?? word
    }

    /// The article a phrase names directly, following plural forms and redirects ("pigeons" → Dove).
    private func articleNamed(_ phrase: String) -> Article? {
        var parts = phrase.split(separator: " ").map(String.init)
        guard let last = parts.popLast() else { return nil }
        for ending in WikiSearchService.singulars(last) {
            let candidate = (parts + [ending]).joined(separator: " ")
            if let article = article(titled: candidate) { return article }
            var target: String?
            step("SELECT target FROM redirects WHERE title_lower = ?", [candidate]) { statement in
                if target == nil { target = WikiSearchService.text(statement, 0) }
            }
            if let target, let article = article(titled: target) { return article }
        }
        return nil
    }

    // MARK: - Scoring

    private func coverage(_ terms: [QueryTerm], _ documentStems: Set<String>) -> Double {
        var total = 0.0
        var got = 0.0
        for term in terms {
            let hit = !term.senses.isDisjoint(with: documentStems)
            if hit || !WikiSearchService.predicateStems.contains(term.stem) { total += term.weight }
            if hit { got += term.weight }
        }
        return total == 0 ? 0 : got / total
    }

    /// Opening sentences up to `prefixCharacters`, plus the best later sentences that mention a
    /// non-subject question word (such as "There are eight planets" sitting past the opening).
    private func buildPassage(lead: String, terms: [QueryTerm], why: Bool, exclude: Set<String>) -> String {
        let sentences = WikiSearchService.sentences(in: lead)
        var chosen: [Int] = []
        var size = 0
        for (index, sentence) in sentences.enumerated() {
            if index > 0, size + sentence.unicodeScalars.count > WikiSearchService.prefixCharacters { break }
            chosen.append(index)
            size += sentence.unicodeScalars.count
        }
        var scored: [(score: Double, index: Int)] = []
        for (index, sentence) in sentences.enumerated() where !chosen.contains(index) {
            let sentenceStems = WikiSearchService.stems(of: sentence)
            let matched = terms.filter { !exclude.contains($0.stem) && !$0.senses.isDisjoint(with: sentenceStems) }
            if !matched.isEmpty {
                let bonus = why && !WikiSearchService.causalStems.isDisjoint(with: sentenceStems) ? 0.5 : 0.0
                scored.append((matched.reduce(0) { $0 + $1.weight } + bonus, index))
            }
        }
        // Python sorts (score, index) descending, so higher scores win and later sentences break ties.
        scored.sort { $0.score == $1.score ? $0.index > $1.index : $0.score > $1.score }
        chosen += scored.prefix(WikiSearchService.extraSentences).map(\.index)
        return chosen.sorted().map { sentences[$0] }.joined(separator: " ")
    }

    private func matchedWeight(_ terms: [QueryTerm], _ documentStems: Set<String>) -> Double {
        terms.reduce(0) { $0 + ($1.senses.isDisjoint(with: documentStems) ? 0 : $1.weight) }
    }

    /// How well the single best sentence of `text` answers the question. Scored per sentence, not
    /// over the whole text, so a 1,000-character opening does not beat a short paragraph just by
    /// being longer.
    private func bestSentenceScore(_ text: String, _ terms: [QueryTerm], why: Bool) -> Double {
        let sentences = WikiSearchService.sentences(in: text)
        return (sentences.isEmpty ? [text] : sentences).reduce(0.0) { best, sentence in
            let sentenceStems = WikiSearchService.stems(of: sentence)
            var score = matchedWeight(terms, sentenceStems)
            if score > 0, why, !WikiSearchService.causalStems.isDisjoint(with: sentenceStems) { score += 0.5 }
            return max(best, score)
        }
    }

    /// The passage to answer from: the article's opening, or the one body paragraph that answers the
    /// question better ("What do they use their trunk for?" → the trunk paragraph). The opening wins
    /// ties.
    private func choosePassage(id: Int64, title: String, lead: String, terms: [QueryTerm],
                               why: Bool, exclude: Set<String> = []) -> (section: String?, text: String) {
        // Words that may move the answer off the opening: not the title or the subject, which every
        // paragraph mentions, and not a premise word unless the question asks why (see premiseStems).
        let titleStems = WikiSearchService.stems(of: title)
        let ranking = terms.filter {
            !exclude.contains($0.stem) && !titleStems.contains($0.stem)
                && (why || !WikiSearchService.premiseStems.contains($0.stem))
        }
        var section: String?
        var paragraph: String?
        if !ranking.isEmpty {
            // A heading match outranks any sentence match ("How many teeth?" → Shark's "Teeth" section,
            // not "teeth-like scales" elsewhere), and within a matching section the first paragraph
            // wins, since a section explains itself before it goes into detail.
            var top = (headingMatch: false, score: bestSentenceScore(lead, ranking, why: why))
            for candidate in paragraphs(of: id) {
                let heading = matchedWeight(ranking, WikiSearchService.stems(of: candidate.section))
                let score = heading > 0
                    ? (headingMatch: true, score: heading)
                    : (headingMatch: false, score: bestSentenceScore(candidate.text, ranking, why: why))
                let better = score.headingMatch != top.headingMatch
                    ? score.headingMatch
                    : score.score > top.score
                if better {
                    top = score
                    section = candidate.section
                    paragraph = candidate.text
                }
            }
        }
        guard let paragraph else {
            return (nil, buildPassage(lead: lead, terms: terms, why: why, exclude: exclude))
        }
        // The opening rides in front of the paragraph, since the answer is often there and the
        // paragraph won on a coincidental word ("litter (family)" for "is it in the bear family?").
        var opening = ""
        for sentence in WikiSearchService.sentences(in: lead) {
            if !opening.isEmpty,
               opening.unicodeScalars.count + sentence.unicodeScalars.count > WikiSearchService.openingCharacters {
                break
            }
            opening += opening.isEmpty ? sentence : " " + sentence
        }
        return (section, opening + " " + buildPassage(lead: paragraph, terms: terms, why: why, exclude: exclude))
    }

    // MARK: - Grounding

    /// Words that carry no fact and so are not expected to appear in the passage.
    private static let linkingWords = wordSet("""
    because cause causes caused causing so then also very really just kind sort way ways
    through make makes made different most known called yes no not
    """)

    /// Calibrated on real answers (Tools/WikiEval/grounding): every invention scored 0.25 or below
    /// (George Washington "killed in a duel" 0.17) and every correct answer 0.31 or above ("No,
    /// pigeons do not eat humans"). The gap is narrow, so re-check it whenever the prompt changes.
    private static let minimumGrounding = 0.28

    /// Whether the answer came from its passage. When the passage doesn't answer the question the
    /// model invents instead, and the safety gate reads for danger, not truth.
    static func isGrounded(answer: String, passage: String) -> Bool {
        groundingScore(answer: answer, passage: passage) >= minimumGrounding
    }

    /// Share of the answer's own words that appear in the passage, with word forms matched loosely
    /// because the model rephrases. The question is not counted, or an answer parroting a false
    /// premise back would score on the child's own words.
    static func groundingScore(answer: String, passage: String) -> Double {
        let content = words(in: answer).filter {
            !stopWords.contains($0) && !linkingWords.contains($0) && !$0.allSatisfy(\.isNumber)
        }
        guard !content.isEmpty else { return 1 }
        let allowed = Set(words(in: passage).map(looseRoot))
        return Double(content.filter { allowed.contains(looseRoot($0)) }.count) / Double(content.count)
    }

    /// A blunter stem than `stem`, for comparing an answer's wording against a passage's.
    static func looseRoot(_ word: String) -> String {
        var root = word
        for suffix in ["ing", "ed", "es", "s", "e"] where root.count > 3 && root.hasSuffix(suffix) {
            root = String(root.dropLast(suffix.count))
            break
        }
        if root.count > 3, let last = root.last, root.dropLast().last == last, !"aeiou".contains(last) {
            root = String(root.dropLast())
        }
        return root
    }

    /// Whether the question brings a subject of its own, so a pronoun in it refers to that subject
    /// rather than to the last article ("Why do elephants use their trunks?" after the Titanic).
    /// A pronoun in the subject slot does point back.
    func namesOwnTopic(_ question: String) -> Bool {
        let raw = WikiSearchService.words(in: question)
        // "Can people climb it?" — the thing asked about is the trailing pronoun, not "people".
        if let last = raw.last, WikiSearchService.pronouns.contains(last) { return false }
        guard let index = raw.firstIndex(where: { WikiSearchService.auxiliaries.contains($0) }) else {
            return false
        }
        if index + 1 < raw.count, WikiSearchService.pronouns.contains(raw[index + 1]) { return false }
        return raw.contains {
            !WikiSearchService.stopWords.contains($0) && !WikiSearchService.titleStopWords.contains($0)
                && articleNamed($0) != nil
        }
    }

    // MARK: - Passage retrieval experiment

    enum RetrievalMode: String, Codable { case sqliteVec = "sqlite-vec", legacy, passages, directPassages = "direct-passages", hybridPassages = "hybrid-passages", calibratedPassages = "calibrated-passages" }

    private struct PassageCandidate {
        let article: Article
        let section: String?
        let text: String
        let coverage: Double
        let lexicalScore: Double
        var sourceID: String? = nil
        var sourceText: String? = nil
    }

    /// Deliberately bounded: at most eight articles, twenty model evaluations, 256 tokens per pair.
    /// The relevance cutoff is provisional; it must be evaluated on held-out questions before shipping.
    private static let articleLimit = 8
    private static let passageLimit = 20
    private static let minimumRelevance = 4.0

    private static let retrievalSynonymGroups = [
        "eat eats ate food feed feeds feeding diet",
        "live lives habitat", "color colour colors colours",
        "big bigger biggest large larger largest size",
        "small smaller smallest tiny little", "tall taller tallest height",
        "long longer longest length", "old older oldest age lifespan",
        "communicate communicates communication", "shape shapes phase phases"
    ]

    private static func retrievalSenses(_ word: String) -> Set<String> {
        let root = stem(word)
        for group in retrievalSynonymGroups {
            let forms = wordSet(group)
            if Set(forms.map(stem)).contains(root) { return forms }
        }
        return [word]
    }

    private func retrievalTerms(_ content: [String]) -> [QueryTerm] {
        var seen = Set<String>()
        return content.compactMap { word in
            let root = Self.stem(word)
            guard seen.insert(root).inserted else { return nil }
            return QueryTerm(stem: root, weight: max(1, min(8, inverseDocumentFrequency(word))),
                             senses: usesHybridRetrieval ? [root] : Set(Self.retrievalSenses(word).map(Self.stem)))
        }
    }

    /// Unlike legacy coverage, missing verbs/properties are counted: matching "armadillo" alone
    /// is not complete evidence for "what do armadillos eat?".
    private func passageCoverage(_ terms: [QueryTerm], _ words: Set<String>) -> Double {
        let total = terms.reduce(0) { $0 + $1.weight }
        return total > 0 ? matchedWeight(terms, words) / total : 0
    }

    /// Contiguous context, preserving qualifiers and negation. No mixing unrelated sentences
    /// from opposite ends of an article. Long individual sentences are skipped, not cut mid-claim.
    private static func passageWindows(_ text: String) -> [String] {
        let parts = sentences(in: text)
        var windows: [String] = []
        for start in parts.indices {
            var chosen: [String] = []
            var count = 0
            for end in start..<min(parts.count, start + 3) {
                let size = parts[end].split(whereSeparator: \.isWhitespace).count
                if count + size > 85 { break }
                chosen.append(parts[end])
                count += size
            }
            if !chosen.isEmpty { windows.append(chosen.joined(separator: " ")) }
        }
        return windows
    }

    func lookUp(_ question: String) -> WikiLookup {
        trace = WikiRetrievalTrace(mode: retrievalMode.rawValue, question: question)
        if usesHybridRetrieval { trace?.retrievalVersion = "hybrid-passages-v3" }
        let start = Date()
        let result: WikiLookup
        switch retrievalMode {
        case .sqliteVec:
            #if canImport(CSQLiteVec)
            result = vectorPassageLookUp(question)
            #else
            result = .notFound(.vectorUnavailable)
            #endif
        case .legacy: result = legacyLookUp(question)
        case .passages: result = passageLookUp(question)
        case .directPassages: result = directPassageLookUp(question)
        case .hybridPassages, .calibratedPassages: result = hybridPassageLookUp(question)
        }
        finishTrace(result, start: start)
        return result
    }

    private func finishTrace(_ result: WikiLookup, start: Date) {
        trace?.elapsedMS = Date().timeIntervalSince(start) * 1000
        switch result {
        case .found(let passage):
            trace?.selectedText = passage.text
            trace?.selectedTitle = passage.title
            trace?.selectedSourceIDs = passage.sourceIDs
        case .notFound(let miss): trace?.rejectionReason = miss.reason
        }
    }

    /// First-stage search has no coverage veto. Titles and original-word BM25 have independent
    /// candidate budgets, so expanded words cannot crowd all exact matches out of the pool.
    private func passageLookUp(_ question: String) -> WikiLookup {
        let raw = Array(Self.words(in: question).prefix(64))
        let content = raw.filter { !Self.stopWords.contains($0) }.map { indexForm($0) }
        guard !content.isEmpty else { return .notFound(.noContentWords) }
        let terms = retrievalTerms(content)
        let ranked = articleCandidates(question: question, raw: raw, content: content, terms: terms)
        guard !ranked.isEmpty else {
            if let unknown = content.first(where: { documentFrequency($0) == 0 }) { return .notFound(.unknownWord(unknown)) }
            return .notFound(.noMatchingArticle)
        }
        return rankPassages(question: question, content: content, terms: terms, articles: ranked)
    }

    private func articleCandidates(question: String, raw: [String], content: [String], terms: [QueryTerm]) -> [Article] {
        var candidates: [Int64: (article: Article, score: Double)] = [:]
        var order: [Int64] = []
        func add(_ article: Article, _ score: Double) {
            if let existing = candidates[article.id] {
                candidates[article.id] = (article, max(existing.score, score))
            } else {
                candidates[article.id] = (article, score)
                order.append(article.id)
            }
        }
        // Use original adjacent words as well as filtered terms so titles containing stop words
        // ("Isle of Man") survive. Do not let filler alone name the subject.
        for sequence in [raw, content] where !sequence.isEmpty {
            for length in stride(from: min(4, sequence.count), through: 1, by: -1) {
                for position in 0...(sequence.count - length) {
                    let gram = Array(sequence[position..<(position + length)])
                    if Self.stopWords.contains(gram[0]) || Self.stopWords.contains(gram.last!) { continue }
                    if length == 1 && (Self.titleStopWords.contains(gram[0]) || gram[0].allSatisfy(\.isNumber)) { continue }
                    if let article = articleNamed(gram.joined(separator: " ")) {
                        add(article, 2 + min(2, Double(length) * 0.5))
                    }
                }
            }
        }
        // Resolve joined words through actual article titles, not speculative spelling edits.
        // Both senses remain candidates (e.g. Goosebumps / Goose bumps).
        for word in content where word.count >= 6 && word.count <= 24 {
            let chars = Array(word)
            for split in 3...(chars.count - 3) {
                if let article = articleNamed(String(chars[..<split]) + " " + String(chars[split...])) {
                    add(article, 2.5)
                }
            }
        }
        let recognized = content.filter { documentFrequency($0) > 0 }
        let expanded = Array(Set(recognized.flatMap { Self.retrievalSenses($0) }).sorted().prefix(32))
        let queryLists: [[String]] = usesHybridRetrieval ? [recognized] : [recognized, expanded]
        for (queryIndex, queryWords) in queryLists.enumerated() where !queryWords.isEmpty {
            let query = queryWords.map { "\"\($0)\"" }.joined(separator: " OR ")
            var ids: [Int64] = []
            step("SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY bm25(fts, 10.0, 1.0), rowid LIMIT \(Self.candidateLimit)", [query]) {
                ids.append(sqlite3_column_int64($0, 0))
            }
            for (rank, id) in ids.enumerated() {
                if let article = article(id: id) {
                    add(article, (queryIndex == 0 ? 1.0 : 0.75) / Double(rank + 1))
                }
            }
        }
        let ranked = order.enumerated().sorted { left, right in
            let l = candidates[left.element]!, r = candidates[right.element]!
            func score(_ candidate: (article: Article, score: Double)) -> Double {
                candidate.score + passageCoverage(terms, Self.stems(of: candidate.article.title + " " + candidate.article.lead))
            }
            let a = score(l), b = score(r)
            return a == b ? left.offset < right.offset : a > b
        }.prefix(Self.articleLimit).map { candidates[$0.element]!.article }
        return ranked
    }

    private func rankPassages(question: String, content: [String], terms: [QueryTerm],
                              articles: [Article]) -> WikiLookup {
        let shortlist = articlePassageCandidates(content: content, terms: terms, articles: articles)
        let unknown = content.filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) && documentFrequency($0) == 0 }
        guard !shortlist.isEmpty else {
            if let unknown = unknown.first { return .notFound(.unknownWord(unknown)) }
            return .notFound(.noMatchingArticle)
        }
        guard let reranker else {
            DebugLog.section("RERANK", "Experiment requires WikiMiniLM; model or vocabulary missing")
            return .notFound(.rerankerUnavailable)
        }
        let scores: [Double]
        let start = Date()
        do {
            scores = try reranker.scores(question: question, passages: shortlist.map(\.text))
            guard scores.count == shortlist.count, scores.allSatisfy(\.isFinite) else { throw WikiRerankerError.missingScore }
        } catch {
            DebugLog.section("RERANK", "Model failed: \(error)")
            return .notFound(.rerankerUnavailable)
        }
        trace?.candidates = shortlist.indices.map {
            WikiEvidenceRecord(sourceID: nil, title: shortlist[$0].article.title,
                section: shortlist[$0].section, text: shortlist[$0].text, relevance: scores[$0])
        }
        let ranked = shortlist.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        let index = ranked[0], top = shortlist[index]
        DebugLog.section("RERANK", "\(shortlist.count) passages, \(Int(Date().timeIntervalSince(start) * 1000)) ms\n"
            + ranked.prefix(5).map { "\(shortlist[$0].article.title) § \(shortlist[$0].section ?? "lead"): \(String(format: "%.2f", scores[$0]))" }.joined(separator: "\n"))
        guard scores[index] >= Self.minimumRelevance else {
            return .notFound(.lowRelevance(scores[index], title: top.article.title))
        }
        return .found(WikiPassage(id: top.article.id, title: top.article.title, lead: top.article.lead,
                                 text: top.text, coverage: top.coverage, section: top.section,
                                 runnersUp: ranked.dropFirst().prefix(2).map { (shortlist[$0].article.title, scores[$0]) }))
    }

    private func articlePassageCandidates(content: [String], terms: [QueryTerm], articles: [Article]) -> [PassageCandidate] {
        let unknown = content.filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) && documentFrequency($0) == 0 }
        var perArticle: [[PassageCandidate]] = []
        let safety = SafetyService()
        for article in articles {
            var titleWords = Self.stems(of: article.title)
            let joinedTitle = Self.words(in: article.title).joined()
            if content.contains(where: { Self.stem($0) == Self.stem(joinedTitle) }) {
                titleWords.insert(Self.stem(joinedTitle))
            }
            // Carry a short identity sentence with body excerpts, preserving species/sense and
            // the classification needed to correct false premises (e.g. a whale is a mammal).
            let identity = Self.sentences(in: article.lead).first.flatMap {
                $0.split(whereSeparator: \.isWhitespace).count <= 45 ? $0 : nil
            }
            let propertyTerms = terms.filter { !titleWords.contains($0.stem) }
            let sources: [(String?, String, String)] = [(nil, article.lead, "a:\(article.id):lead")]
                + paragraphs(of: article.id).map { (Optional($0.section), $0.text, "a:\(article.id):p:\($0.ordinal)") }
            var seen = Set<String>()
            var passages: [PassageCandidate] = []
            for (section, source, sourceID) in sources {
                for text in Self.passageWindows(source) where seen.insert(text).inserted {
                    let evidence = titleWords.union(Self.stems(of: (section ?? "") + " " + text))
                    // Unknown terms can occur in the body even when absent from the lead index.
                    // They remain constraints so a fictional subject is not silently dropped.
                    guard unknown.allSatisfy({ evidence.contains(Self.stem($0)) }) else { continue }
                    let bodyWords = Self.stems(of: text)
                    let coverage = passageCoverage(terms, evidence)
                    let propertyCoverage = passageCoverage(propertyTerms, bodyWords)
                    guard terms.isEmpty || coverage >= 0.25 else { continue }
                    // Screen complete, independently retrieved windows; never remove blocked
                    // words from an otherwise unsafe window and pass the fragments onward.
                    let context = identity.map { text.hasPrefix($0) ? "" : $0 + " " } ?? ""
                    let presented = article.title + ": " + context + text
                    guard safety.safePassage(presented) != nil else { continue }
                    let score = coverage + 2 * propertyCoverage
                    passages.append(PassageCandidate(article: article, section: section, text: presented,
                                                     coverage: coverage, lexicalScore: score, sourceID: sourceID, sourceText: source))
                }
            }
            passages = passages.enumerated().sorted {
                $0.element.lexicalScore == $1.element.lexicalScore ? $0.offset < $1.offset
                    : $0.element.lexicalScore > $1.element.lexicalScore
            }.map(\.element)
            perArticle.append(passages)
        }
        // Reserve two passages per article before filling spare slots. One long article must
        // not monopolize the model's entire budget. Stable order keeps evaluation reproducible.
        var shortlist = perArticle.flatMap { Array($0.prefix(2)) }
        let remaining = perArticle.flatMap { Array($0.dropFirst(2)) }.enumerated().sorted {
            $0.element.lexicalScore == $1.element.lexicalScore ? $0.offset < $1.offset
                : $0.element.lexicalScore > $1.element.lexicalScore
        }.map(\.element)
        shortlist += remaining.prefix(max(0, Self.passageLimit - shortlist.count))
        shortlist = Array(shortlist.prefix(Self.passageLimit))
        return shortlist
    }

    // MARK: - Direct paragraph FTS5 experiment

    private func directPassageLookUp(_ query: String, rerankQuestion: String? = nil,
                                     articleID: Int64? = nil) -> WikiLookup {
        guard hasPassageIndex else { return .notFound(.passageIndexUnavailable) }
        // FTS5's porter tokenizer handles morphology. No synonym tables or lead-only word veto.
        var candidates = directCandidates(query, articleID: articleID, limit: Self.passageLimit)
        guard !candidates.isEmpty else { return .notFound(.noMatchingArticle) }
        trace?.candidates = candidates.map(\.record)
        guard let reranker else { return .notFound(.rerankerUnavailable) }
        let scores: [Double]
        do {
            scores = try reranker.scores(question: rerankQuestion ?? query, passages: candidates.map { $0.record.text })
            guard scores.count == candidates.count, scores.allSatisfy(\.isFinite) else { throw WikiRerankerError.missingScore }
        } catch { return .notFound(.rerankerUnavailable) }
        for i in candidates.indices { candidates[i].record.relevance = scores[i] }
        trace?.candidates = candidates.map(\.record)
        let order = candidates.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        let best = candidates[order[0]]
        // Retained for controlled A/B comparison, NOT an answerability decision. Record below-
        // cutoff candidates too, so evaluation can measure evidence lost through this gate.
        guard scores[order[0]] >= Self.minimumRelevance else {
            return .notFound(.lowRelevance(scores[order[0]], title: best.article.title))
        }
        return .found(WikiPassage(id: best.article.id, title: best.article.title, lead: best.article.lead,
            text: best.record.text, coverage: nil, section: best.record.section,
            runnersUp: order.dropFirst().prefix(2).map { (candidates[$0].article.title, scores[$0]) },
            sourceIDs: best.record.sourceID.map { [$0] } ?? []))
    }

    private func directCandidates(_ query: String, articleID: Int64? = nil, limit: Int, sourceIDs: [String]? = nil) -> [(record: WikiEvidenceRecord, article: Article)] {
        let terms = Array(Set(Self.words(in: query).filter { !Self.stopWords.contains($0) }).sorted().prefix(32))
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        let scope = articleID.map { "AND d.article = \($0)" } ?? ""
        var documents: [(id: String, article: Article, ordinal: Int, section: String, text: String)] = []
        if let sourceIDs {
            for id in sourceIDs.prefix(256) {
                step("SELECT d.source_id,d.article,d.ordinal,d.title,a.lead,d.section,d.text FROM passage_documents d JOIN articles a ON a.id=d.article WHERE d.source_id=?", [id]) {
                    documents.append((Self.text($0, 0), Article(id: sqlite3_column_int64($0, 1), title: Self.text($0, 3), lead: Self.text($0, 4)), Int(sqlite3_column_int64($0, 2)), Self.text($0, 5), Self.text($0, 6)))
                }
            }
        } else {
        step("""
            SELECT d.source_id, d.article, d.ordinal, d.title, a.lead, d.section, d.text
            FROM passage_fts JOIN passage_documents d ON d.id=passage_fts.rowid
            JOIN articles a ON a.id=d.article
            WHERE passage_fts MATCH ? \(scope)
            ORDER BY bm25(passage_fts, 3.0, 1.0, 1.0), passage_fts.rowid LIMIT 48
            """, [match]) {
            documents.append((Self.text($0, 0), Article(id: sqlite3_column_int64($0, 1),
                title: Self.text($0, 3), lead: Self.text($0, 4)), Int(sqlite3_column_int64($0, 2)),
                Self.text($0, 5), Self.text($0, 6)))
        }
        }
        trace?.retrievedSources = documents.map {
            WikiEvidenceRecord(sourceID: $0.id, title: $0.article.title, section: $0.section,
                               text: $0.text, relevance: nil)
        }
        guard !documents.isEmpty else { return [] }
        let safety = SafetyService()
        let queryStems = Set(terms.map(Self.stem))
        var candidates: [(record: WikiEvidenceRecord, article: Article)] = []
        var seen = Set<String>()
        // One best contiguous window from each BM25 hit before spending spare slots on second
        // windows. This bounds inference while keeping different sources in contention.
        var windows: [[(record: WikiEvidenceRecord, article: Article)]] = []
        for document in documents {
            var source = document.text
            // Carry the previous sentence only within this section; it can contain the referent
            // or qualifier of a short paragraph. Never join across unrelated headings.
            if document.ordinal > 0 {
                step("SELECT text FROM paragraphs WHERE article=\(document.article.id) AND ord=\(document.ordinal-1) AND section=?", [document.section]) {
                    if let previous = Self.sentences(in: Self.text($0, 0)).last,
                       previous.split(whereSeparator: \.isWhitespace).count <= 35 {
                        source = previous + " " + source
                    }
                }
            }
            // Keep a short paragraph whole, even when it has more than three sentences.
            // Otherwise a definition can lose the sentence explaining its function.
            var excerpts = source.split(whereSeparator: \.isWhitespace).count <= 90
                ? [source] : Self.passageWindows(source)
            // Do not silently discard a paragraph containing a single long sentence. The model
            // tokenizer enforces its own input bound; truncation remains visible in evaluation.
            if excerpts.isEmpty { excerpts = [source] }
            let ranked = excerpts.enumerated().sorted {
                let left = queryStems.intersection(Self.stems(of: $0.element)).count
                let right = queryStems.intersection(Self.stems(of: $1.element)).count
                return left == right ? $0.offset < $1.offset : left > right
            }.map(\.element)
            let identity = Self.sentences(in: document.article.lead).first.flatMap {
                $0.split(whereSeparator: \.isWhitespace).count <= 35 ? $0 : nil
            }
            windows.append(ranked.prefix(2).compactMap { excerpt in
                let prefix = document.ordinal >= 0 ? identity.map { excerpt.contains($0) ? "" : $0 + " " } ?? "" : ""
                let text = document.article.title + ": " + prefix + excerpt
                guard safety.safePassage(text) != nil else { return nil }
                return (WikiEvidenceRecord(sourceID: document.id, title: document.article.title,
                    section: document.section.isEmpty ? nil : document.section, text: text, relevance: nil), document.article)
            })
        }
        for slot in 0..<2 {
            for group in windows where group.count > slot {
                let candidate = group[slot]
                if seen.insert(sourceIDs == nil ? candidate.record.text : (candidate.record.sourceID ?? "") + "|" + candidate.record.text).inserted { candidates.append(candidate) }
                if candidates.count == limit { break }
            }
            if candidates.count == limit { break }
        }
        return candidates
    }

    private static func mergeWindows(_ a: PassageCandidate, _ b: PassageCandidate) -> String? {
        guard a.sourceID != nil, a.sourceID == b.sourceID else { return nil }
        let title = a.article.title + ": "
        let identity = sentences(in: a.article.lead).first ?? ""
        func body(_ text: String) -> [String] {
            var text = String(text.dropFirst(title.count))
            if !identity.isEmpty, text.hasPrefix(identity) { text = String(text.dropFirst(identity.count)).trimmingCharacters(in: .whitespaces) }
            return text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let x = body(a.text), y = body(b.text)
        var joined: [String]?
        if a.text.contains(b.text) { return a.text }
        if b.text.contains(a.text) { return b.text }
        for (left, right) in [(x, y), (y, x)] where joined == nil {
            let maximum = min(left.count, right.count)
            if maximum > 0 {
                for overlap in stride(from: maximum, through: 1, by: -1) {
                    if left.suffix(overlap).elementsEqual(right.prefix(overlap)) {
                        joined = left + right.dropFirst(overlap); break
                    }
                }
            }
        }
        guard let joined, let original = a.sourceText,
              original.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(joined.joined(separator: " ")) else { return nil }
        let carried = a.text.hasPrefix(title + identity) && !identity.isEmpty ? identity + " " : ""
        let result = title + carried + joined.joined(separator: " ")
        guard result.split(whereSeparator: \.isWhitespace).count <= 125 else { return nil }
        return result
    }

    /// Merge two independently retrieved pools before the single bounded reranker call.
    /// No new topic rules or synonym lists: direct body search supplies lexical alternatives.
    private func hybridPassageLookUp(_ question: String, rerankQuestion: String? = nil,
                                     scopedArticle: Article? = nil) -> WikiLookup {
        guard hasPassageIndex else { return .notFound(.passageIndexUnavailable) }
        let raw = Array(Self.words(in: question).prefix(64))
        let content = raw.filter { !Self.stopWords.contains($0) }.map { indexForm($0) }
        guard !content.isEmpty else { return .notFound(.noContentWords) }
        let terms = retrievalTerms(content)
        let articles = scopedArticle.map { [$0] }
            ?? articleCandidates(question: question, raw: raw, content: content, terms: terms)
        let articlePool = articlePassageCandidates(content: content, terms: terms, articles: articles)
        let bodyPool = directCandidates(question, articleID: scopedArticle?.id, limit: 48)
        var merged: [(record: WikiEvidenceRecord, article: Article)] = []
        var seen = Set<String>()
        func append(_ candidate: (record: WikiEvidenceRecord, article: Article)) {
            let key = Self.words(in: candidate.record.text).joined(separator: " ")
            if seen.insert(key).inserted { merged.append(candidate) }
        }
        // Merge overlapping windows of the SAME source before allocating slots. This retains
        // their supporting sentences while avoiding two model calls for nearly identical text.
        var compact: [PassageCandidate] = []
        for candidate in articlePool {
            if let index = compact.indices.first(where: {
                compact[$0].sourceID == candidate.sourceID && Self.mergeWindows(compact[$0], candidate) != nil
            }), let combined = Self.mergeWindows(compact[index], candidate) {
                let old = compact[index]
                compact[index] = PassageCandidate(article: old.article, section: old.section,
                    text: combined, coverage: max(old.coverage, candidate.coverage),
                    lexicalScore: max(old.lexicalScore, candidate.lexicalScore), sourceID: old.sourceID, sourceText: old.sourceText)
            } else { compact.append(candidate) }
        }
        var groups = articles.map { article in compact.filter { $0.article.id == article.id } }
        while groups.contains(where: { !$0.isEmpty }) && merged.count < Self.passageLimit {
            for i in groups.indices where !groups[i].isEmpty && merged.count < Self.passageLimit {
                let p = groups[i].removeFirst()
                append((WikiEvidenceRecord(sourceID: p.sourceID, title: p.article.title,
                                           section: p.section, text: p.text, relevance: nil), p.article))
            }
        }
        // Fill the freed slots from direct body search, prioritizing different articles.
        var bodyArticles = Set<Int64>()
        let bodyDiverse = bodyPool.filter { bodyArticles.insert($0.article.id).inserted }
        for p in bodyDiverse + bodyPool where merged.count < Self.passageLimit {
            // A complete source already represented in the pool needs no duplicate model call.
            if !merged.contains(where: { $0.record.sourceID == p.record.sourceID && $0.record.text.contains(p.record.text) }) { append(p) }
        }
        guard !merged.isEmpty else { return .notFound(.noMatchingArticle) }
        trace?.candidates = merged.map(\.record)
        guard let reranker else { return .notFound(.rerankerUnavailable) }
        let scores: [Double]
        do {
            scores = try reranker.scores(question: rerankQuestion ?? question, passages: merged.map { $0.record.text })
            guard scores.count == merged.count, scores.allSatisfy(\.isFinite) else { throw WikiRerankerError.missingScore }
        } catch { return .notFound(.rerankerUnavailable) }
        for i in merged.indices { merged[i].record.relevance = scores[i] }
        trace?.candidates = merged.map(\.record)
        let order = merged.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        let best = merged[order[0]]
        var threshold = Self.minimumRelevance
        trace?.rerankerIdentity = reranker.modelIdentity
        trace?.gateVersion = "baseline-4"
        if retrievalMode == .calibratedPassages {
            guard let gate = calibratedGate, gate.threshold.isFinite,
                  gate.version == "support-cutoff-v1", gate.retrievalVersion == "hybrid-passages-v3",
                  gate.rerankerIdentity == reranker.modelIdentity else { return .notFound(.calibrationUnavailable) }
            threshold = gate.threshold
            trace?.gateVersion = gate.version
        }
        trace?.gateThreshold = threshold
        guard scores[order[0]] >= threshold else {
            return .notFound(.lowRelevance(scores[order[0]], title: best.article.title))
        }
        return .found(WikiPassage(id: best.article.id, title: best.article.title, lead: best.article.lead,
            text: best.record.text, coverage: nil, section: best.record.section,
            runnersUp: order.dropFirst().prefix(2).map { (merged[$0].article.title, scores[$0]) },
            sourceIDs: best.record.sourceID.map { [$0] } ?? []))
    }

    #if canImport(CSQLiteVec)
    /// Native equivalent of the frozen binary-vector experiment. No question-specific rules,
    /// no gate change, and no silent keyword fallback when vector assets fail validation.
    private func vectorPassageLookUp(_ question: String, rerankQuestion: String? = nil) -> WikiLookup {
        trace?.retrievalVersion = "sqlite-vec-binary-rrf-v1"
        trace?.retrievalQuestion = question
        trace?.gateVersion = "baseline-4"
        trace?.gateThreshold = Self.minimumRelevance
        guard hasPassageIndex else { return .notFound(.passageIndexUnavailable) }
        let raw = Array(Self.words(in: question).prefix(64))
        let content = raw.filter { !Self.stopWords.contains($0) }.map { indexForm($0) }
        guard !content.isEmpty else { return .notFound(.noContentWords) }
        let neighbors: (hits: [(id: Int64, distance: Double)], embeddingMS: Double, searchMS: Double)
        do {
            let started = Date()
            if vectorIndex == nil {
                guard let vectorAssets else { throw WikiVectorError.incompatibleAssets("missing bundled assets") }
                vectorIndex = try WikiVectorIndex(assets: vectorAssets)
            }
            trace?.vectorInitializationMS = Date().timeIntervalSince(started) * 1000
            guard let vectorIndex else { throw WikiVectorError.incompatibleAssets("missing index") }
            trace?.vectorCorpusSHA256 = vectorIndex.manifest.corpusSHA256
            trace?.vectorIndexSHA256 = vectorIndex.manifest.indexSHA256
            neighbors = try vectorIndex.neighbors(question)
        } catch {
            trace?.vectorError = String(describing: error)
            DebugLog.section("VECTOR", "Cannot run SQLite-vec experiment: \(error)")
            return .notFound(.vectorUnavailable)
        }
        trace?.vectorEmbeddingMS = neighbors.embeddingMS
        trace?.vectorSearchMS = neighbors.searchMS
        var dense: [String] = []
        for hit in neighbors.hits {
            step("SELECT source_id FROM passage_documents WHERE id=\(hit.id)") { dense.append(Self.text($0, 0)) }
        }
        guard dense.count == neighbors.hits.count else {
            trace?.vectorError = "vector IDs missing from matching corpus"
            return .notFound(.vectorUnavailable)
        }
        trace?.vectorSourceIDs = dense
        trace?.vectorDistances = neighbors.hits.map(\.distance)
        let terms = retrievalTerms(content)
        let articles = articleCandidates(question: question, raw: raw, content: content, terms: terms)
        let articleIDs = articlePassageCandidates(content: content, terms: terms, articles: articles).compactMap(\.sourceID)
        let bodyIDs = directCandidates(question, limit: 48).compactMap { $0.record.sourceID }
        let sourceIDs = WikiRankFusion.unique(articleIDs + bodyIDs + dense)
        let prepared = directCandidates(question, limit: 512, sourceIDs: sourceIDs)
        var available: [String: (record: WikiEvidenceRecord, article: Article)] = [:]
        for candidate in prepared {
            if let id = candidate.record.sourceID, available[id] == nil { available[id] = candidate }
        }
        let ids = WikiRankFusion.shortlist(article: articleIDs, body: bodyIDs, dense: dense,
                                          prepared: available.mapValues(\.record))
        var shortlist = ids.compactMap { available[$0] }
        guard !shortlist.isEmpty else { return .notFound(.noMatchingArticle) }
        trace?.candidates = shortlist.map(\.record)
        guard let reranker else { return .notFound(.rerankerUnavailable) }
        let scores: [Double]
        do {
            scores = try reranker.scores(question: rerankQuestion ?? question, passages: shortlist.map { $0.record.text })
            guard scores.count == shortlist.count, scores.allSatisfy(\.isFinite) else { throw WikiRerankerError.missingScore }
        } catch { return .notFound(.rerankerUnavailable) }
        for i in shortlist.indices { shortlist[i].record.relevance = scores[i] }
        trace?.candidates = shortlist.map(\.record)
        trace?.rerankerIdentity = reranker.modelIdentity
        let order = shortlist.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        let best = shortlist[order[0]]
        DebugLog.section("VECTOR", "SQLite-vec binary: \(dense.count) neighbours, \(shortlist.count) reranked; search \(Int(neighbors.searchMS)) ms; selected \(best.article.title), score \(scores[order[0]])")
        guard scores[order[0]] >= Self.minimumRelevance else {
            return .notFound(.lowRelevance(scores[order[0]], title: best.article.title))
        }
        return .found(WikiPassage(id: best.article.id, title: best.article.title, lead: best.article.lead,
            text: best.record.text, coverage: nil, section: best.record.section,
            runnersUp: order.dropFirst().prefix(2).map { (shortlist[$0].article.title, scores[$0]) },
            sourceIDs: best.record.sourceID.map { [$0] } ?? []))
    }
    #endif

    // MARK: - Legacy lookup

    /// Searches for a passage answering `question` on its own, with no conversation history.
    private func legacyLookUp(_ question: String) -> WikiLookup {
        let raw = WikiSearchService.words(in: question)
        let content = raw.filter { !WikiSearchService.stopWords.contains($0) }.map { indexForm($0) }
        if content.isEmpty { return .notFound(.noContentWords) }
        for word in content where word.count >= 3 && !word.allSatisfy(\.isNumber) {
            if documentFrequency(word) == 0 { return .notFound(.unknownWord(word)) }
        }
        let why = raw.contains("why")

        var terms: [QueryTerm] = []
        var termIndex: [String: Int] = [:]
        for word in content {
            let stem = WikiSearchService.stem(word)
            guard termIndex[stem] == nil else { continue }
            termIndex[stem] = terms.count
            terms.append(QueryTerm(stem: stem, weight: inverseDocumentFrequency(word),
                                   senses: WikiSearchService.synonyms[stem] ?? [stem]))
        }

        var matches: [(position: Int, length: Int, article: Article)] = []
        for length in stride(from: min(4, content.count), through: 1, by: -1) {
            for position in 0...(content.count - length) {
                let gram = Array(content[position..<(position + length)])
                if length == 1, WikiSearchService.titleStopWords.contains(gram[0]) || gram[0].allSatisfy(\.isNumber) {
                    continue
                }
                if let article = articleNamed(gram.joined(separator: " ")) {
                    matches.append((position, length, article))
                }
            }
        }
        // The subject is the first title match, unless a later one is far more specific ("prehistoric
        // platypuses" → Platypus, not Prehistory). Pure rarity was much worse (Frog → Diet), so the
        // later match must be rarer by `subjectMargin`: pairs that must not swap reach 2.28, ones
        // that should reach 3.46.
        func specificity(_ match: (position: Int, length: Int, article: Article)) -> Double {
            content[match.position..<(match.position + match.length)]
                .map(inverseDocumentFrequency).max() ?? 0
        }
        var subject = matches.min { ($0.position, -$0.length) < ($1.position, -$1.length) }
        if let chosen = subject {
            var rarest = chosen
            for match in matches where specificity(match) > specificity(rarest) { rarest = match }
            if specificity(rarest) - specificity(chosen) >= WikiSearchService.subjectMargin {
                subject = rarest
            }
        }

        struct Candidate {
            let article: Article
            var titleLength: Int
            var bm25Bonus: Double
        }
        var candidates: [Candidate] = []
        var candidateIndex: [Int64: Int] = [:]
        for match in matches {
            if let index = candidateIndex[match.article.id] {
                candidates[index].titleLength = max(candidates[index].titleLength, match.length)
            } else {
                candidateIndex[match.article.id] = candidates.count
                candidates.append(Candidate(article: match.article, titleLength: match.length, bm25Bonus: 0))
            }
        }

        let ftsQuery = content.map { "\"\($0)\"" }.joined(separator: " OR ")
        var found: [Int64] = []
        step("SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY bm25(fts, 10.0, 1.0) LIMIT \(WikiSearchService.candidateLimit)",
             [ftsQuery]) { statement in
            found.append(sqlite3_column_int64(statement, 0))
        }
        for (rank, id) in found.enumerated() {
            let bonus = 0.5 * (1 - Double(rank) / Double(WikiSearchService.candidateLimit))
            if let index = candidateIndex[id] {
                candidates[index].bm25Bonus = bonus
            } else if let article = article(id: id) {
                candidateIndex[id] = candidates.count
                candidates.append(Candidate(article: article, titleLength: 0, bm25Bonus: bonus))
            }
        }

        struct Ranked {
            let score: Double
            let coverage: Double
            let article: Article
            let isSubject: Bool
            let order: Int
        }
        var ranked: [Ranked] = []
        for (order, candidate) in candidates.enumerated() {
            let articleCoverage = coverage(terms, WikiSearchService.stems(of: candidate.article.title + " " + candidate.article.lead))
            let sentences = WikiSearchService.sentences(in: candidate.article.lead)
            let best = (sentences.isEmpty ? [""] : sentences).map { sentence -> Double in
                let sentenceStems = WikiSearchService.stems(of: sentence)
                let bonus = why && !WikiSearchService.causalStems.isDisjoint(with: sentenceStems) ? 0.3 : 0.0
                return coverage(terms, sentenceStems) + bonus
            }.max() ?? 0
            let isSubject = subject?.article.id == candidate.article.id
            let score = Double(candidate.titleLength) + (isSubject ? 2.0 : 0.0)
                + 2.0 * articleCoverage + best + candidate.bm25Bonus
            ranked.append(Ranked(score: score, coverage: articleCoverage, article: candidate.article,
                                 isSubject: isSubject, order: order))
        }
        // Python's sort is stable, so equal scores keep the order candidates were collected in.
        ranked.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }

        guard let top = ranked.first else { return .notFound(.noMatchingArticle) }
        if top.coverage < WikiSearchService.minimumCoverage {
            return .notFound(.lowCoverage(top.coverage, title: top.article.title))
        }
        var exclude: Set<String> = []
        if top.isSubject, let subject {
            exclude = Set(content[subject.position..<(subject.position + subject.length)].map(WikiSearchService.stem))
        }
        let passage = choosePassage(id: top.article.id, title: top.article.title, lead: top.article.lead,
                                    terms: terms, why: why, exclude: exclude)
        return .found(WikiPassage(
            id: top.article.id,
            title: top.article.title,
            lead: top.article.lead,
            text: passage.text,
            coverage: top.coverage,
            section: passage.section,
            runnersUp: ranked.dropFirst().prefix(2).map { (title: $0.article.title, score: $0.score) }))
    }

    /// Answers a follow-up from the article the previous question used, picking the sentences that
    /// match the new question ("What about the smallest?" → the Mercury sentence of Planet).
    func reuse(_ question: String, id: Int64, title: String, lead: String, previousQuestion: String? = nil) -> WikiLookup {
        trace = WikiRetrievalTrace(mode: retrievalMode.rawValue, question: question)
        if usesHybridRetrieval { trace?.retrievalVersion = "hybrid-passages-v3" }
        let started = Date()
        let result = reuseLookup(question, id: id, title: title, lead: lead, previousQuestion: previousQuestion)
        finishTrace(result, start: started)
        return result
    }

    private func reuseLookup(_ question: String, id: Int64, title: String, lead: String, previousQuestion: String?) -> WikiLookup {
        #if canImport(CSQLiteVec)
        if retrievalMode == .sqliteVec {
            let resolved = "Current question: \(question). Topic: \(title). " + (previousQuestion.map { "Previous question: \($0)" } ?? "")
            // Reuse the existing session's topic; this is not a learned resolver. Vector search
            // remains corpus-wide, and sees the same topic-appended query as keyword search.
            return vectorPassageLookUp(question + " " + title, rerankQuestion: resolved)
        }
        #endif
        if usesHybridRetrieval {
            let resolved = "Current question: \(question). Topic: \(title). " + (previousQuestion.map { "Previous question: \($0)" } ?? "")
            return hybridPassageLookUp(question + " " + title, rerankQuestion: resolved,
                                      scopedArticle: Article(id: id, title: title, lead: lead))
        }
        if retrievalMode == .directPassages {
            // Preserve the existing topic policy for this retrieval-only experiment. Entity
            // resolution from the previous answer is a separate, measured training task.
            let resolved = "Current question: \(question). Topic: \(title). " + (previousQuestion.map { "Previous question: \($0)" } ?? "")
            return directPassageLookUp(question + " " + title, rerankQuestion: resolved, articleID: id)
        }
        if retrievalMode == .passages {
            let content = Self.words(in: question).filter { !Self.stopWords.contains($0) }.map { indexForm($0) }
            let resolved = "Current question: \(question). Topic: \(title). " + (previousQuestion.map { "Previous question: \($0)" } ?? "")
            return rankPassages(question: resolved, content: content, terms: retrievalTerms(content),
                                articles: [Article(id: id, title: title, lead: lead)])
        }
        let raw = WikiSearchService.words(in: question)
        let content = raw.filter { !WikiSearchService.stopWords.contains($0) }.map { indexForm($0) }
        // The whole article, since a follow-up may ask about something the opening never names.
        let body = paragraphs(of: id).map { $0.section + " " + $0.text }.joined(separator: " ")
        let articleStems = WikiSearchService.stems(of: title + " " + lead + " " + body)
        let required = content.filter { !WikiSearchService.predicateStems.contains(WikiSearchService.stem($0)) }
        if !required.isEmpty, !required.contains(where: { articleStems.contains(WikiSearchService.stem($0)) }) {
            return .notFound(.articleLacksWords(required, title: title))
        }
        var terms: [QueryTerm] = []
        var termIndex: [String: Int] = [:]
        for word in content {
            let stem = WikiSearchService.stem(word)
            let term = QueryTerm(stem: stem, weight: inverseDocumentFrequency(word),
                                 senses: WikiSearchService.synonyms[stem] ?? [stem])
            // As in the Python dict comprehension, a repeated stem keeps its place but takes the later
            // word's weight.
            if let index = termIndex[stem] { terms[index] = term } else {
                termIndex[stem] = terms.count
                terms.append(term)
            }
        }
        let passage = choosePassage(id: id, title: title, lead: lead, terms: terms, why: raw.contains("why"))
        return .found(WikiPassage(
            id: id,
            title: title,
            lead: lead,
            text: passage.text,
            coverage: nil,
            section: passage.section,
            runnersUp: []))
    }
}

/// One child's conversation: decides whether a question is a follow-up and, if so, answers it from
/// the article the previous question used.
actor WikiSearchSession {

    struct Outcome {
        let lookup: WikiLookup
        /// The article title a follow-up reused; nil for a fresh search.
        let reusedTopic: String?
        var trace: WikiRetrievalTrace? = nil
    }

    private let service: WikiSearchService
    private var askedQuestions: [String] = []
    private var topic: (id: Int64, title: String, lead: String)?

    init(service: WikiSearchService) {
        self.service = service
    }

    /// Starts a new conversation — nothing is carried over.
    func reset() {
        askedQuestions = []
        topic = nil
    }

    func lookUp(_ question: String) async -> Outcome {
        let raw = WikiSearchService.words(in: question)
        let content = raw.filter { !WikiSearchService.stopWords.contains($0) }
        let recentStems = Set(askedQuestions.suffix(2)
            .flatMap { WikiSearchService.words(in: $0) }
            .map(WikiSearchService.stem))
        let hasPronoun = raw.contains { WikiSearchService.pronouns.contains($0) }
        let hasNewTopicWord = content.contains {
            !recentStems.contains(WikiSearchService.stem($0)) && !WikiSearchService.titleStopWords.contains($0)
        }
        let introducesTopic = await service.namesOwnTopic(question)
        let isFollowUp = topic != nil && (hasPronoun || !hasNewTopicWord) && !introducesTopic
        let hasOwnSubject = content.contains { !WikiSearchService.predicateStems.contains(WikiSearchService.stem($0)) }
        // "they/he/she" always point back at something, as does a trailing "it" ("can people climb
        // it?"); a leading "it" is often just grammar ("why is it cold at night?") and can search.
        let pointsBack = raw.contains { WikiSearchService.referringWords.contains($0) }
            || (raw.last.map { WikiSearchService.pronouns.contains($0) } ?? false)

        let lookup: WikiLookup
        var reusedTopic: String?
        if isFollowUp, let topic {
            reusedTopic = topic.title
            lookup = await service.reuse(question, id: topic.id, title: topic.title, lead: topic.lead, previousQuestion: askedQuestions.last)
        } else if !introducesTopic, pointsBack || (hasPronoun && !hasOwnSubject) {
            lookup = .notFound(.noTopicToReferTo)
        } else {
            lookup = await service.lookUp(question)
        }

        switch lookup {
        case .found(let passage):
            topic = (passage.id, passage.title, passage.lead)
        case .notFound:
            // A follow-up that finds nothing keeps the conversation's topic; a fresh question clears it.
            if !isFollowUp { topic = nil }
        }
        askedQuestions.append(question)
        let noLookup: Bool
        if case .notFound(.noTopicToReferTo) = lookup { noLookup = true } else { noLookup = false }
        return Outcome(lookup: lookup, reusedTopic: reusedTopic,
                       trace: noLookup ? nil : await service.retrievalTrace())
    }
}

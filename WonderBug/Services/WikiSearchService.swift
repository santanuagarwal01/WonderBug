//
//  WikiSearchService.swift
//  WonderBug
//

import Foundation
import SQLite3

/// One article's opening text, trimmed to the sentences that answer the question.
struct WikiPassage {
    let title: String
    /// The article's whole stored opening — kept so a follow-up question can reuse this article.
    let lead: String
    /// The sentences handed to the answer model.
    let text: String
    /// Share of the question the article covers; nil when a follow-up reused the previous article.
    let coverage: Double?
    let runnersUp: [(title: String, score: Double)]
}

/// Why the search has no passage. The distinction matters because some misses let the model answer
/// from its own knowledge and others must not: a word Wikipedia has never seen is how invented
/// creatures ("a flurbin bird") reach the model, and it answers those with invented facts rather
/// than saying it doesn't know.
enum WikiMiss {
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

    /// Whether the model may answer this question from its own knowledge instead. False for the two
    /// cases where it has nothing to go on and would invent something.
    var allowsUnsourcedAnswer: Bool {
        switch self {
        case .noMatchingArticle, .lowCoverage, .articleLacksWords: return true
        case .noContentWords, .unknownWord, .noTopicToReferTo: return false
        }
    }

    /// The console/report line, unchanged from when this was a plain string.
    var reason: String {
        switch self {
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
/// This is a direct port of `Tools/WikiEval/eval_v2.py`, which is the reference implementation the
/// question sets are scored against: same word lists, same scoring, same gates. Keep the two in
/// step — `Tools/WikiEval/compare_picks.py` diffs a run of each over the same questions.
///
/// Uses SQLite directly rather than SwiftData, which cannot do full-text search. The index is built
/// with FTS5 `detail='none'`, so only single-word MATCH queries work (no multi-word phrases).
/// An actor so the SQLite work stays off the main thread; the view model awaits it.
actor WikiSearchService {

    // MARK: - Tuning (mirrors eval_v2.py)

    private static let minimumCoverage = 0.6
    private static let prefixCharacters = 400
    private static let extraSentences = 2
    private static let candidateLimit = 30

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
    meant mean called kind type lot lots get got let lets please ever name
    dont doesnt isnt arent didnt wasnt werent hasnt havent hadnt shouldnt aint
    """)

    /// Describing words (verbs, adjectives, and the measurement words of "how tall / long / far"
    /// questions): never the subject of a question, so never a one-word title match.
    static let titleStopWords = wordSet("""
    make makes made eat eats live lives need needs jump jumps swim swims breathe biggest smallest big
    small full good first daily color colour cold hot six eight both land orange blue fish
    tall taller tallest long longer longest far farther old older heavy heavier deep deeper wide wider
    high higher fast faster
    """)

    static let pronouns = wordSet("it its they them their theirs he him his she her one ones this that these those")

    /// Words that always point back at something already discussed.
    static let referringWords = wordSet("they them their theirs he him his she her hers")

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

    private let database: OpaquePointer
    private let articleCount: Double
    private var documentFrequencies: [String: Int] = [:]
    private static let transientText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL) throws {
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
    }

    deinit {
        sqlite3_close(database)
    }

    /// The index shipped inside the app. Xcode's synchronized groups flatten resource folders, so
    /// the file sits at the top level of the bundle rather than under Resources/.
    static func bundled() -> WikiSearchService? {
        guard let url = Bundle.main.url(forResource: "simplewiki", withExtension: "db") else { return nil }
        return try? WikiSearchService(databaseURL: url)
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

    private func article(id: Int64) -> Article? {
        var found: Article?
        step("SELECT id, title, lead FROM articles WHERE id = \(id)") { statement in
            found = Article(id: sqlite3_column_int64(statement, 0),
                            title: WikiSearchService.text(statement, 1),
                            lead: WikiSearchService.text(statement, 2))
        }
        return found
    }

    private func article(titled title: String) -> Article? {
        var found: Article?
        step("SELECT id, title, lead FROM articles WHERE title = ? COLLATE NOCASE", [title]) { statement in
            if found == nil {
                found = Article(id: sqlite3_column_int64(statement, 0),
                                title: WikiSearchService.text(statement, 1),
                                lead: WikiSearchService.text(statement, 2))
            }
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

    /// The article a phrase names directly, following plural forms and redirects ("pigeons" → Dove).
    private func articleNamed(_ phrase: String) -> Article? {
        var parts = phrase.split(separator: " ").map(String.init)
        guard let last = parts.popLast() else { return nil }
        var endings = [last]
        if last.hasSuffix("ies") { endings.append(String(last.dropLast(3)) + "y") }
        if last.hasSuffix("es") { endings.append(String(last.dropLast(2))) }
        if last.hasSuffix("s") { endings.append(String(last.dropLast())) }
        for ending in endings {
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

    // MARK: - Lookup

    /// Searches for a passage answering `question` on its own, with no conversation history.
    func lookUp(_ question: String) -> WikiLookup {
        let raw = WikiSearchService.words(in: question)
        let content = raw.filter { !WikiSearchService.stopWords.contains($0) }
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
        let subject = matches.min { ($0.position, -$0.length) < ($1.position, -$1.length) }

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
        return .found(WikiPassage(
            title: top.article.title,
            lead: top.article.lead,
            text: buildPassage(lead: top.article.lead, terms: terms, why: why, exclude: exclude),
            coverage: top.coverage,
            runnersUp: ranked.dropFirst().prefix(2).map { (title: $0.article.title, score: $0.score) }))
    }

    /// Answers a follow-up from the article the previous question used, picking the sentences that
    /// match the new question ("What about the smallest?" → the Mercury sentence of Planet).
    func reuse(_ question: String, title: String, lead: String) -> WikiLookup {
        let raw = WikiSearchService.words(in: question)
        let content = raw.filter { !WikiSearchService.stopWords.contains($0) }
        let leadStems = WikiSearchService.stems(of: title + " " + lead)
        let required = content.filter { !WikiSearchService.predicateStems.contains(WikiSearchService.stem($0)) }
        if !required.isEmpty, !required.contains(where: { leadStems.contains(WikiSearchService.stem($0)) }) {
            return .notFound(.articleLacksWords(required, title: title))
        }
        var terms: [QueryTerm] = []
        var termIndex: [String: Int] = [:]
        for word in content {
            let stem = WikiSearchService.stem(word)
            let term = QueryTerm(stem: stem, weight: inverseDocumentFrequency(word),
                                 senses: WikiSearchService.synonyms[stem] ?? [stem])
            // Matching the Python dict comprehension: a repeated stem keeps its place but takes the
            // later word's weight.
            if let index = termIndex[stem] { terms[index] = term } else {
                termIndex[stem] = terms.count
                terms.append(term)
            }
        }
        return .found(WikiPassage(
            title: title,
            lead: lead,
            text: buildPassage(lead: lead, terms: terms, why: raw.contains("why"), exclude: []),
            coverage: nil,
            runnersUp: []))
    }
}

/// One child's conversation: decides whether a question is a follow-up and, if so, answers it from
/// the article the previous question used.
actor WikiSearchSession {

    struct Outcome {
        let lookup: WikiLookup
        /// The article title a follow-up reused, for logging and tests; nil for a fresh search.
        let reusedTopic: String?
    }

    private let service: WikiSearchService
    private var askedQuestions: [String] = []
    private var topic: (title: String, lead: String)?

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
        let isFollowUp = topic != nil && (hasPronoun || !hasNewTopicWord)
        let hasOwnSubject = content.contains { !WikiSearchService.predicateStems.contains(WikiSearchService.stem($0)) }
        // "they/he/she" always point back at something, as does a trailing "it" ("can people climb
        // it?"); a leading "it" is often just grammar ("why is it cold at night?") and can search.
        let pointsBack = raw.contains { WikiSearchService.referringWords.contains($0) }
            || (raw.last.map { WikiSearchService.pronouns.contains($0) } ?? false)

        let lookup: WikiLookup
        var reusedTopic: String?
        if isFollowUp, let topic {
            reusedTopic = topic.title
            lookup = await service.reuse(question, title: topic.title, lead: topic.lead)
        } else if pointsBack || (hasPronoun && !hasOwnSubject) {
            lookup = .notFound(.noTopicToReferTo)
        } else {
            lookup = await service.lookUp(question)
        }

        switch lookup {
        case .found(let passage):
            topic = (passage.title, passage.lead)
        case .notFound:
            // A follow-up that finds nothing keeps the conversation's topic; a fresh question clears it.
            if !isFollowUp { topic = nil }
        }
        askedQuestions.append(question)
        return Outcome(lookup: lookup, reusedTopic: reusedTopic)
    }
}

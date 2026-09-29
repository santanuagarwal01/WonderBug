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
    /// Share of the question the article covers; nil when a follow-up reused the previous article.
    let coverage: Double?
    /// The heading of the body section the passage came from; nil when it came from the opening.
    let section: String?
    let runnersUp: [(title: String, score: Double)]
}

/// Why the search has no passage. The child always gets "I don't know yet"; the reason is for the
/// debug log and the evaluation reports.
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
/// A direct port of `Tools/WikiEval/eval_v2.py`, the reference the question sets are scored against:
/// keep the two in step (`Tools/WikiEval/compare_picks.py` diffs them). SQLite directly, since
/// SwiftData cannot do full-text search; the FTS5 index is `detail='none'`, so only single-word
/// MATCH queries work. An actor, so the SQLite work stays off the main thread.
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
    /// only once an article has been chosen.
    private func paragraphs(of id: Int64) -> [(section: String, text: String)] {
        var found: [(section: String, text: String)] = []
        step("SELECT section, text FROM paragraphs WHERE article = \(id) ORDER BY ord") { statement in
            found.append((WikiSearchService.text(statement, 0), WikiSearchService.text(statement, 1)))
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

    // MARK: - Lookup

    /// Searches for a passage answering `question` on its own, with no conversation history.
    func lookUp(_ question: String) -> WikiLookup {
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
    func reuse(_ question: String, id: Int64, title: String, lead: String) -> WikiLookup {
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
            lookup = await service.reuse(question, id: topic.id, title: topic.title, lead: topic.lead)
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
        return Outcome(lookup: lookup, reusedTopic: reusedTopic)
    }
}

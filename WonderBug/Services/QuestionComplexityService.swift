//
//  QuestionComplexityService.swift
//  WonderBug
//

import Foundation

/// Rule-based classification of a question's phrasing (spec §8 "Pattern Detection"), so parents can
/// follow how a child's questions change over time. It matches words and phrases only, so it is an
/// approximation. Where the spec's categories overlap, its rule order (L4 → L3 → L2 → L1, first
/// match wins) is followed over its examples.
struct QuestionComplexityAnalysis {
    /// 1 (simple fact lookup) through 4 (reasoning, cause and effect, theory of mind).
    let level: Int
    /// Whether the question contains "and", "but", "if", "because" or "so".
    let hasConnector: Bool
    let wordCount: Int
    /// Whether the phrasing depends on something said earlier ("Why don't they?"). Only a real
    /// follow-up when there was an earlier turn.
    let referencesEarlierContext: Bool
}

protocol QuestionComplexityAnalyzing {
    func analyze(_ question: String) -> QuestionComplexityAnalysis
}

struct QuestionComplexityService: QuestionComplexityAnalyzing {

    // MARK: Connector words (whole words, so "so" never matches inside "some")
    private let connectorWords: Set<String> = ["and", "but", "if", "because", "so"]

    // MARK: Level 4A — Causal Reasoning
    private let causalWords: Set<String> = [
        "why",
        "affect", "affects", "affected", "affecting",
        "impact", "impacts", "impacted",
        "influence", "influences", "influenced",
        "result", "results", "resulting", "resulted"
    ]
    private let causalPhrases: [String] = [
        "how come", "how did",
        "what cause", "what causes",
        "what causing", "what is causing", "whats causing",
        "what caused", "what is caused", "whats caused",
        "what makes", "what made",
        "what making", "what is making", "whats making"
    ]

    // MARK: Level 4B — Hypothetical / Prediction. "happen" anywhere with "if" covers
    // "would/could happen ... if".
    private let hypotheticalPhrases: [String] = [
        "what if", "might happen", "what might", "how would", "how might", "how could"
    ]
    private let happenWords: Set<String> = ["happen", "happens", "happened"]

    // MARK: Level 4C — Theory of Mind / Intent / Internal States
    private let theoryOfMindWords: Set<String> = [
        "think", "thinks", "thinking", "thought",
        "believe", "believes", "believed", "believing",
        "feel", "feels", "feeling", "felt",
        "want", "wants", "wanted",
        "know", "knows", "knew",
        "decide", "decides", "decided",
        "choose", "chooses", "chose"
    ]

    // MARK: Level 3A — Comparison
    private let comparisonWords: Set<String> = [
        "compare", "compared", "comparing",
        "different", "difference", "same", "similar",
        "than", "versus", "vs", "between"
    ]

    // MARK: Level 3B — Classification / Group Relationships
    private let groupWords: Set<String> = [
        "group", "groups", "type", "types", "kind", "kinds",
        "category", "categories", "class", "classes",
        "family", "families",
        "belong", "belongs", "belonged",
        "classified", "classify", "classification"
    ]

    // MARK: Level 3C — Relationship Words
    private let relationshipWords: Set<String> = [
        "related", "relates", "relatedness", "relationship", "relationships",
        "connected", "connects", "connection",
        "ancestor", "ancestors", "descended", "descend",
        "evolve", "evolves", "evolved", "evolution"
    ]

    // MARK: Level 3D — Broad Claims / Evaluation. "all"/"every" counts only with an auxiliary verb,
    // so "Tell me all about frogs" is not a broad claim.
    private let absoluteWords: Set<String> = ["always", "never"]
    private let universalWords: Set<String> = ["all", "every"]
    private let auxiliaryVerbs: Set<String> = ["are", "is", "do", "does", "can", "will"]

    // MARK: Level 2A — Classification / Diversity Exploration
    private let diversityWords: Set<String> = [
        "species", "example", "examples", "variety", "varieties",
        "other", "another", "split", "splits", "divided", "division", "divisions"
    ]
    private let diversityPhrases: [String] = ["different kinds", "groups of"]

    // MARK: Level 2B — Example-Seeking ("example" is already caught by 2A)
    private let exampleWords: Set<String> = ["common", "commonly", "famous", "main"]
    private let examplePhrases: [String] = ["most common"]

    // MARK: Level 2C — General Patterns / Variation. A quantity word counts only with an auxiliary
    // verb, and "many" not as part of "how many", which is a Level 1 starter.
    private let quantityWords: Set<String> = ["some", "most", "few"]

    // MARK: Level 2D — Understanding / Simple Processes (question starters — must lead the question)
    private let level2Starters: [String] = ["how do", "how does", "can", "could", "is", "are", "do", "does"]

    // MARK: Level 1 — Simple Fact Retrieval (question starters — must lead the question)
    private let level1Starters: [String] = ["what", "where", "when", "who", "which", "how many", "how much", "name"]

    func analyze(_ question: String) -> QuestionComplexityAnalysis {
        let normalized = question
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let paddedWords = " " + words.joined(separator: " ") + " "

        let wordSet = Set(words)
        func hasAnyWord(_ set: Set<String>) -> Bool {
            !wordSet.isDisjoint(with: set)
        }
        func hasAnyPhrase(_ phrases: [String]) -> Bool {
            phrases.contains { paddedWords.contains(" \($0) ") }
        }
        func startsWithAny(_ starters: [String]) -> Bool {
            starters.contains { normalized.hasPrefix($0) }
        }
        let hasMany = words.contains("many") && !paddedWords.contains(" how many ")
        let hasIf = wordSet.contains("if")

        return QuestionComplexityAnalysis(
            level: level(
                hasAnyWord: hasAnyWord, hasAnyPhrase: hasAnyPhrase,
                startsWithAny: startsWithAny, hasMany: hasMany, hasIf: hasIf
            ),
            hasConnector: hasAnyWord(connectorWords),
            wordCount: words.count,
            referencesEarlierContext: hasAnyWord(Self.referenceWords)
        )
    }

    /// Level 4, then 3, then 2, then 1; first match wins, and Level 2 when nothing matches.
    private func level(
        hasAnyWord: (Set<String>) -> Bool,
        hasAnyPhrase: ([String]) -> Bool,
        startsWithAny: ([String]) -> Bool,
        hasMany: Bool,
        hasIf: Bool
    ) -> Int {
        // Level 4 — Reasoning, Cause & Effect, Theory of Mind
        if hasAnyWord(causalWords) || hasAnyPhrase(causalPhrases) {
            return 4
        }
        if hasAnyPhrase(hypotheticalPhrases) || (hasAnyWord(happenWords) && hasIf) {
            return 4
        }
        if hasAnyWord(theoryOfMindWords) {
            return 4
        }

        // Level 3 — Relationships, Comparisons, Evaluation
        if hasAnyWord(comparisonWords) {
            return 3
        }
        if hasAnyWord(groupWords) {
            return 3
        }
        if hasAnyWord(relationshipWords) {
            return 3
        }
        if hasAnyWord(absoluteWords) || (hasAnyWord(universalWords) && hasAnyWord(auxiliaryVerbs)) {
            return 3
        }

        // Level 2 — Classification, Examples, Understanding
        if hasAnyWord(diversityWords) || hasAnyPhrase(diversityPhrases) {
            return 2
        }
        if hasAnyWord(exampleWords) || hasAnyPhrase(examplePhrases) {
            return 2
        }
        if (hasAnyWord(quantityWords) || hasMany) && hasAnyWord(auxiliaryVerbs) {
            return 2
        }
        if startsWithAny(level2Starters) {
            return 2
        }

        // Level 1 — Simple Fact Retrieval
        if startsWithAny(level1Starters) {
            return 1
        }

        return 2
    }

    /// Pronouns and comparative references a self-contained question wouldn't need
    /// ("Why cant they", "Is it bigger", "What about the Atlantic").
    private static let referenceWords: Set<String> = [
        "they", "them", "their", "it", "its", "he", "she", "his", "her",
        "those", "these", "that", "this", "there", "also", "too", "else"
    ]
}

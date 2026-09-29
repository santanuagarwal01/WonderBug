//
//  HomeViewModel.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 08/07/26.
//

import Foundation
import SwiftUI
import Combine

/// Drives the ask-a-question flow: safety gate, Wikipedia search, answer generation, follow-up
/// context and history. Shared by `HomeView` and `AnswerView`, owned by `MainTabView`.
@MainActor
final class HomeViewModel: ObservableObject {

    @Published var question: String = ""
    @Published var answer: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let answerService: AnswerServicing
    /// Nil when the bundled Wikipedia index can't be opened; every question then gets "I don't know yet".
    private let wikiSession: WikiSearchSession?
    private let safetyService: SafetyServicing
    private let complexityService: QuestionComplexityAnalyzing
    private var historyRepository: HistoryRepositoryProtocol?
    private var conversationContext: [AnswerData] = []
    private var pendingBlockedQuestion: String?

    private let maxContextTurns = 5

    static let unknownAnswer = "Great question! Smart thinking, I don't know yet."

    init(
        answerService: AnswerServicing,
        wikiSession: WikiSearchSession? = nil,
        safetyService: SafetyServicing = SafetyService(),
        complexityService: QuestionComplexityAnalyzing = QuestionComplexityService()
    ) {
        self.answerService = answerService
        self.wikiSession = wikiSession
        self.safetyService = safetyService
        self.complexityService = complexityService
    }

    /// Called once the SwiftUI environment's `ModelContext` is available.
    func configure(historyRepository: HistoryRepositoryProtocol) {
        self.historyRepository = historyRepository
    }

    /// Question safety → Wikipedia passage → passage safety → model → answer safety → grounding →
    /// history. Every answer comes from a passage: when there is none, or it is unsafe, the model is
    /// never run and the child gets "I don't know yet", since answering from the model's own
    /// knowledge was the largest source of invented answers.
    func submit() async {

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuestion.isEmpty else {
            return
        }

        isLoading = true
        errorMessage = nil
        DebugLog.question(trimmedQuestion)

        // Recorded in history for the parent view; a follow-up needs an earlier turn to follow.
        let analysis = complexityService.analyze(trimmedQuestion)
        let isFollowUpQuestion = analysis.referencesEarlierContext && !conversationContext.isEmpty

        let isContinuationOfBlockedTopic = pendingBlockedQuestion != nil
            && safetyService.isBareFollowUp(trimmedQuestion)
        let verdict: SafetyVerdict = isContinuationOfBlockedTopic
            ? .blocked
            : safetyService.evaluate(trimmedQuestion)

        if verdict == .blocked {
            DebugLog.section("SAFETY", isContinuationOfBlockedTopic
                ? "Question blocked: bare follow-up to an earlier blocked question"
                : "Question blocked by the word list")
            showBlockedResponse(for: trimmedQuestion, analysis: analysis, isFollowUp: isFollowUpQuestion)
            isLoading = false
            return
        }

        pendingBlockedQuestion = nil

        func giveUp() {
            DebugLog.section("RESULT", "Showing \"don't know\" without running the model")
            showUnknownAnswer(for: trimmedQuestion, analysis: analysis, isFollowUp: isFollowUpQuestion)
            isLoading = false
        }

        guard let wikiSession else {
            DebugLog.section("SEARCH", "No bundled index, so there is no passage to answer from")
            giveUp()
            return
        }
        let outcome = await wikiSession.lookUp(trimmedQuestion)
        guard case .found(let found) = outcome.lookup else {
            if case .notFound(let miss) = outcome.lookup {
                DebugLog.section("SEARCH", "Nothing found: \(miss.reason)")
            }
            giveUp()
            return
        }
        let how = outcome.reusedTopic.map { "follow-up, reused \"\($0)\"" }
            ?? "coverage \(found.coverage.map { String(format: "%.2f", $0) } ?? "-")"
        let runnersUp = found.runnersUp.map { "\($0.title) (\(String(format: "%.2f", $0.score)))" }
            .joined(separator: ", ")
        DebugLog.section("SEARCH", "Found \"\(found.title)\" (\(how))\nRunners-up: \(runnersUp.isEmpty ? "none" : runnersUp)")
        DebugLog.section("PASSAGE", found.text)
        guard let passage = safetyService.safePassage(found.text) else {
            DebugLog.section("SAFETY", "Passage rejected: it contains a blocked word or phrase")
            giveUp()
            return
        }

        // Earlier turns go to the model only for a follow-up (the search reused the previous
        // article), and only the turns about that article: anything else leaks into the answer, as
        // when frogs were given Jupiter's "great red spot".
        let promptContext = outcome.reusedTopic.map { topic in conversationContext.filter { $0.topic == topic } } ?? []

        do {
            let generatedAnswer = try await answerService.generateAnswer(
                for: trimmedQuestion,
                context: promptContext,
                passage: passage
            )

            if generatedAnswer.isEmpty {
                DebugLog.section("RESULT", "Model returned nothing after cleanup; showing an error")
                errorMessage = "Something went wrong. Please try again."
            } else if safetyService.evaluateAnswer(generatedAnswer) == .blocked {
                DebugLog.section("SAFETY", "Answer blocked by the word list")
                showBlockedResponse(for: trimmedQuestion, analysis: analysis, isFollowUp: isFollowUpQuestion)
            } else if !WikiSearchService.isGrounded(answer: generatedAnswer, passage: passage) {
                // When the passage doesn't answer the question the model invents rather than stopping.
                DebugLog.section("GROUNDING", "Answer is not from the passage; showing \"don't know\"")
                showUnknownAnswer(for: trimmedQuestion, analysis: analysis, isFollowUp: isFollowUpQuestion)
            } else {
                let emoji = TopicEmoji.emoji(title: found.title, question: trimmedQuestion)
                answer = emoji.map { "\(generatedAnswer) \($0)" } ?? generatedAnswer
                DebugLog.section("SHOWN", answer)
                // Recorded without the emoji, since the model is told to write none.
                conversationContext.append(AnswerData(question: trimmedQuestion, answer: generatedAnswer,
                                                      topic: found.title))
                conversationContext = Array(conversationContext.suffix(maxContextTurns))
                saveToHistory(
                    question: trimmedQuestion,
                    answer: answer,
                    isBlocked: false,
                    analysis: analysis,
                    isFollowUp: isFollowUpQuestion
                )
            }
        } catch {
            DebugLog.section("RESULT", "Model failed: \(error)")
            errorMessage = "Something went wrong. Please try again."
        }

        isLoading = false
    }

    /// The question and answer `submit()` just produced; nil when it ended in an error.
    var shownAnswer: AnswerData? {
        answer.isEmpty ? nil : AnswerData(question: question, answer: answer)
    }

    /// Clears the question and answer on screen. The conversation context and a pending blocked
    /// topic are kept, so follow-ups still resolve; a fresh app launch resets them.
    func clear() {
        question = ""
        answer = ""
        errorMessage = nil
    }

    private func showUnknownAnswer(for question: String, analysis: QuestionComplexityAnalysis, isFollowUp: Bool) {
        answer = Self.unknownAnswer
        saveToHistory(question: question, answer: answer, isBlocked: false, analysis: analysis, isFollowUp: isFollowUp)
    }

    /// Shows the fixed refusal and keeps the topic blocked for bare follow-ups. The question stays out
    /// of the model's context and is flagged in history.
    private func showBlockedResponse(
        for question: String,
        analysis: QuestionComplexityAnalysis,
        isFollowUp: Bool
    ) {
        pendingBlockedQuestion = question
        answer = SafetyService.blockedResponse
        saveToHistory(
            question: question,
            answer: answer,
            isBlocked: true,
            analysis: analysis,
            isFollowUp: isFollowUp
        )
    }

    /// Best effort: a storage failure must never break the ask flow.
    private func saveToHistory(
        question: String,
        answer: String,
        isBlocked: Bool,
        analysis: QuestionComplexityAnalysis,
        isFollowUp: Bool
    ) {
        guard let historyRepository else {
            print("⚠️ saveToHistory: historyRepository is nil — configure(historyRepository:) was never called")
            return
        }

        do {
            try historyRepository.save(
                question: question,
                answer: answer,
                isBlocked: isBlocked,
                complexityLevel: analysis.level,
                hasConnector: analysis.hasConnector,
                isFollowUp: isFollowUp,
                questionLengthWords: analysis.wordCount
            )
        } catch {
            print("⚠️ saveToHistory failed: \(error)")
        }
    }
}

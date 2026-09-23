//
//  HomeViewModel.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 08/07/26.
//

import Foundation
import SwiftUI
import Combine

/// Drives the ask-a-question flow: runs the safety gate, calls the answer service, tracks
/// follow-up context across turns, and persists every Q&A to history. Shared by `HomeView`
/// (input) and `AnswerView` (display), owned by `MainTabView`.
@MainActor
final class HomeViewModel: ObservableObject {

    @Published var question: String = ""
    @Published var answer: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var isAnswerBlocked: Bool = false

    private let answerService: AnswerServicing
    /// Nil when the app runs without the bundled Wikipedia index, in which case the model answers
    /// from its own knowledge as it did before grounding.
    private let wikiSession: WikiSearchSession?
    private let safetyService: SafetyServicing
    private let complexityService: QuestionComplexityAnalyzing
    private var historyRepository: HistoryRepositoryProtocol?
    private var conversationContext: [AnswerData] = []
    private var pendingBlockedQuestion: String?

    /// Follow-up context kept in memory. Small on purpose: the on-device model's prompt should
    /// stay short, and older turns stop being useful for resolving references like "they".
    private let maxContextTurns = 5

    /// Shown when the search finds nothing safe to answer from. The model is not run at all in that
    /// case, which is the only reliable way to stop it inventing an answer.
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

    /// Injects the history repository after init — it needs the SwiftUI environment's
    /// `ModelContext`, which isn't available when the view model is first created.
    func configure(historyRepository: HistoryRepositoryProtocol) {
        self.historyRepository = historyRepository
    }

    /// Handles one "Ask" tap end-to-end: trim → safety check (including blocked-topic follow-up
    /// tracking) → Wikipedia passage lookup → generate an answer from that passage → safety check on
    /// the answer → save to history. Each step is printed to the console by `DebugLog` in debug builds.
    func submit() async {

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuestion.isEmpty else {
            return
        }

        isLoading = true
        errorMessage = nil
        DebugLog.question(trimmedQuestion)

        // Pattern Detection (spec §8): classified once per question, regardless of safety verdict —
        // the classification reflects the question's own phrasing, independent of whether it was
        // safe to answer. "is_follow_up" additionally requires real prior context to exist (not
        // just follow-up-shaped wording), so an isolated "why not" with an empty session doesn't
        // count as a follow-up even though it reads like one.
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
        isAnswerBlocked = false

        // Look up a Wikipedia passage first, and filter it for anything a child should not read.
        //
        // When there is no passage the model may still answer from its own knowledge, but only where
        // it has something real to work from. A word no article contains ("a flurbin bird", a typo) and
        // a "they/it" question with no topic are the two cases where it reliably invents an answer
        // instead, so those still show "I don't know yet" without running it. A passage rejected as
        // unsafe never falls through either: that topic was ruled out, not merely unfound.
        var passage: String?
        var passageTitle: String?
        if let wikiSession {
            let outcome = await wikiSession.lookUp(trimmedQuestion)
            switch outcome.lookup {
            case .found(let found):
                passage = safetyService.safePassage(found.text)
                passageTitle = found.title
                let how = outcome.reusedTopic.map { "follow-up, reused \"\($0)\"" }
                    ?? "coverage \(found.coverage.map { String(format: "%.2f", $0) } ?? "-")"
                let runnersUp = found.runnersUp.map { "\($0.title) (\(String(format: "%.2f", $0.score)))" }
                    .joined(separator: ", ")
                DebugLog.section("SEARCH", "Found \"\(found.title)\" (\(how))\nRunners-up: \(runnersUp.isEmpty ? "none" : runnersUp)")
                DebugLog.section("PASSAGE", found.text)
                if passage == nil {
                    DebugLog.section("SAFETY", "Passage rejected: it contains a blocked word or phrase")
                    DebugLog.section("RESULT", "Showing \"don't know\" without running the model")
                    showUnknownAnswer(for: trimmedQuestion, analysis: analysis, isFollowUp: isFollowUpQuestion)
                    isLoading = false
                    return
                }
            case .notFound(let miss):
                DebugLog.section("SEARCH", "Nothing found: \(miss.reason)")
                guard miss.allowsUnsourcedAnswer else {
                    DebugLog.section("RESULT", "Showing \"don't know\" without running the model")
                    showUnknownAnswer(for: trimmedQuestion, analysis: analysis, isFollowUp: isFollowUpQuestion)
                    isLoading = false
                    return
                }
                DebugLog.section("FALLBACK", "No passage — the model answers from its own knowledge")
            }
        }

        do {
            let generatedAnswer = try await answerService.generateAnswer(
                for: trimmedQuestion,
                context: conversationContext,
                passage: passage
            )

            if generatedAnswer.isEmpty {
                DebugLog.section("RESULT", "Model returned nothing after cleanup; showing an error")
                errorMessage = "Something went wrong. Please try again."
            } else if safetyService.evaluate(generatedAnswer) == .blocked {
                DebugLog.section("SAFETY", "Answer blocked by the word list")
                // The model can bring up unsafe detail the question never asked for (e.g. inventing
                // an arrest for a real person), so its answer passes the same gate the question did.
                showBlockedResponse(for: trimmedQuestion, analysis: analysis, isFollowUp: isFollowUpQuestion)
            } else {
                let emoji = TopicEmoji.emoji(title: passageTitle, question: trimmedQuestion)
                answer = emoji.map { "\(generatedAnswer) \($0)" } ?? generatedAnswer
                DebugLog.section("SHOWN", answer)
                // The model's own earlier answers go back to it without the app's emoji, since its
                // instructions say to write none.
                conversationContext.append(AnswerData(question: trimmedQuestion, answer: generatedAnswer))
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

    /// Clears the typed question and shown answer so the child can ask something new.
    /// Deliberately does NOT clear `conversationContext` or `pendingBlockedQuestion`:
    /// follow-up questions ("Why don't they?") need the prior turns to resolve references,
    /// and a blocked topic must stay blocked across "Ask another question" taps. Both live
    /// only in memory, so a fresh app launch is the natural session boundary that resets them.
    func clear() {
        question = ""
        answer = ""
        errorMessage = nil
        isAnswerBlocked = false
    }

    /// Shows the "I don't know yet" line — when the search found nothing safe to answer from — and
    /// saves it to history like any other answer.
    private func showUnknownAnswer(for question: String, analysis: QuestionComplexityAnalysis, isFollowUp: Bool) {
        answer = Self.unknownAnswer
        saveToHistory(question: question, answer: answer, isBlocked: false, analysis: analysis, isFollowUp: isFollowUp)
    }

    /// Replaces the answer with the fixed refusal and treats the question as a blocked topic: it stays
    /// out of the model's follow-up context, bare follow-ups to it stay blocked, and it is saved to
    /// history flagged for the parent view.
    private func showBlockedResponse(
        for question: String,
        analysis: QuestionComplexityAnalysis,
        isFollowUp: Bool
    ) {
        pendingBlockedQuestion = question
        answer = SafetyService.blockedResponse
        isAnswerBlocked = true
        saveToHistory(
            question: question,
            answer: answer,
            isBlocked: true,
            analysis: analysis,
            isFollowUp: isFollowUp
        )
    }

    /// Best-effort persistence — a storage failure should never break the child's ask flow.
    /// Errors are logged (not surfaced to the child) so a silent storage failure is at least
    /// visible in the console during development.
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
            _ = try historyRepository.save(
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

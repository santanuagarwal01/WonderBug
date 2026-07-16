//
//  HomeViewModel.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 08/07/26.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class HomeViewModel: ObservableObject {

    @Published var question: String = ""
    @Published var answer: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var isAnswerBlocked: Bool = false

    private let answerService: AnswerServicing
    private let safetyService: SafetyServicing
    private var historyRepository: HistoryRepositoryProtocol?
    private var conversationContext: [AnswerData] = []
    private var pendingBlockedQuestion: String?

    /// Follow-up context kept in memory. Small on purpose: the on-device model's prompt should
    /// stay short, and older turns stop being useful for resolving references like "they".
    private let maxContextTurns = 5

    init(
        answerService: AnswerServicing = StubAnswerService(),
        safetyService: SafetyServicing = SafetyService()
    ) {
        self.answerService = answerService
        self.safetyService = safetyService
    }

    func configure(historyRepository: HistoryRepositoryProtocol) {
        self.historyRepository = historyRepository
    }

    func submit() async {

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuestion.isEmpty else {
            return
        }

        isLoading = true
        errorMessage = nil

        let isContinuationOfBlockedTopic = pendingBlockedQuestion != nil
            && safetyService.isBareFollowUp(trimmedQuestion)
        let verdict: SafetyVerdict = isContinuationOfBlockedTopic
            ? .blocked
            : safetyService.evaluate(trimmedQuestion)

        if verdict == .blocked {
            pendingBlockedQuestion = trimmedQuestion
            answer = SafetyService.blockedResponse
            isAnswerBlocked = true
            saveToHistory(question: trimmedQuestion, answer: answer, isBlocked: true)
            isLoading = false
            return
        }

        pendingBlockedQuestion = nil
        isAnswerBlocked = false

        do {
            let generatedAnswer = try await answerService.generateAnswer(
                for: trimmedQuestion,
                context: conversationContext
            )

            if generatedAnswer.isEmpty {
                errorMessage = "Something went wrong. Please try again."
            } else {
                answer = generatedAnswer
                conversationContext.append(AnswerData(question: trimmedQuestion, answer: generatedAnswer))
                conversationContext = Array(conversationContext.suffix(maxContextTurns))
                saveToHistory(question: trimmedQuestion, answer: generatedAnswer, isBlocked: false)
            }
        } catch {
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

    private func saveToHistory(question: String, answer: String, isBlocked: Bool) {
        _ = try? historyRepository?.save(question: question, answer: answer, isBlocked: isBlocked)
    }
}

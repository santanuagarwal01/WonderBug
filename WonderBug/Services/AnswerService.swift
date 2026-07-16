//
//  AnswerService.swift
//  WonderBug
//

import Foundation

/// Seam for generating an answer to an already-safety-checked question.
/// `StubAnswerService` stands in until the offline model (Qwen) is wired up — everything else
/// in the app (storage, history, safety) is built against this protocol and won't need to change.
protocol AnswerServicing {
    func generateAnswer(for question: String, context: [AnswerData]) async throws -> String
}

struct StubAnswerService: AnswerServicing {
    func generateAnswer(for question: String, context: [AnswerData]) async throws -> String {
        try await Task.sleep(for: .milliseconds(500))
        return "Stars twinkle because"
    }
}

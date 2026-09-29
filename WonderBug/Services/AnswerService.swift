//
//  AnswerService.swift
//  WonderBug
//

import Foundation

/// Generates an answer to an already safety-checked question from the Wikipedia passage it must
/// come from. `QwenAnswerService` is the implementation.
protocol AnswerServicing {
    func generateAnswer(for question: String, context: [AnswerData], passage: String) async throws -> String
}

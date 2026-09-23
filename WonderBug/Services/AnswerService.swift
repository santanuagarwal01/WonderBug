//
//  AnswerService.swift
//  WonderBug
//

import Foundation

/// Seam for generating an answer to an already-safety-checked question. Everything else in the
/// app (storage, history, safety) is built against this protocol, so the underlying model can be
/// swapped without touching the rest of the code — `QwenAnswerService` is the implementation.
///
/// `passage` is the Wikipedia text the answer must come from. It is nil only when the app runs
/// without the bundled index; the view model never asks for an answer when the search found
/// nothing, so the model cannot invent one.
protocol AnswerServicing {
    func generateAnswer(for question: String, context: [AnswerData], passage: String?) async throws -> String
}

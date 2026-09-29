//
//  AnswerData.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 09/07/26.
//

import Foundation

/// A question paired with its answer: the answer on screen, or an earlier turn sent to the model as
/// follow-up context.
struct AnswerData {
    let question: String
    let answer: String
    /// The Wikipedia article the answer came from; a follow-up is sent only the turns about its own
    /// article.
    let topic: String?

    init(question: String, answer: String, topic: String? = nil) {
        self.question = question
        self.answer = answer
        self.topic = topic
    }
}

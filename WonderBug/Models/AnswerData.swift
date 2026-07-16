//
//  AnswerData.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 09/07/26.
//

import Foundation

/// A question paired with its answer — used both as the currently-displayed answer state
/// (Home/MainTabView/AnswerView) and as a prior turn offered as follow-up context to the
/// answer service (see `AnswerServicing.generateAnswer(for:context:)`).
struct AnswerData {
    let question: String
    let answer: String
    let isBlocked: Bool

    init(question: String, answer: String, isBlocked: Bool = false) {
        self.question = question
        self.answer = answer
        self.isBlocked = isBlocked
    }
}

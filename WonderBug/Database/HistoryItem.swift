//
//  HistoryItem.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 10/07/26.
//

import Foundation
import SwiftData

/// One asked question and the answer it received, as parents see it in the History tab.
/// `isBlocked` marks questions the safety gate refused.
@Model
final class HistoryItem {

    @Attribute(.unique)
    var id: UUID

    var question: String
    var answer: String
    var isBlocked: Bool

    var createdAt: Date

    // The question's complexity classification (see `QuestionComplexityService`). These need inline
    // defaults: SwiftData's lightweight migration reads them to backfill rows saved before they existed.
    var complexityLevel: Int = 1
    var hasConnector: Bool = false
    var isFollowUp: Bool = false
    var questionLengthWords: Int = 0

    init(
        question: String,
        answer: String,
        isBlocked: Bool,
        complexityLevel: Int,
        hasConnector: Bool,
        isFollowUp: Bool,
        questionLengthWords: Int
    ) {
        self.id = UUID()
        self.question = question
        self.answer = answer
        self.isBlocked = isBlocked
        self.createdAt = Date()
        self.complexityLevel = complexityLevel
        self.hasConnector = hasConnector
        self.isFollowUp = isFollowUp
        self.questionLengthWords = questionLengthWords
    }
}

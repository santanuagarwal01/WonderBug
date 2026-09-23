//
//  HistoryItem.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 10/07/26.
//

import Foundation
import SwiftData

/// SwiftData record of one asked question and the answer it received — the persistent log
/// parents review in the History tab. `isBlocked` marks questions the safety gate refused,
/// so the parent view can filter to flagged entries only.
@Model
final class HistoryItem {
    
    @Attribute(.unique)
    var id: UUID
    
    var question: String
    var answer: String
    var isBlocked: Bool

    var createdAt: Date

    // Pattern Detection (spec §8): rule-based classification of the question's phrasing, captured
    // for future parent-facing "cognitive growth" reporting. Not surfaced in any UI yet.
    //
    // These four need an inline default (not just a default on the init parameter below) —
    // SwiftData's automatic lightweight migration reads the property declaration itself to
    // backfill mandatory attributes on rows that predate this schema version. Without it,
    // migration fails outright with "missing attribute values on mandatory destination attribute".
    var complexityLevel: Int = 1
    var hasConnector: Bool = false
    var isFollowUp: Bool = false
    var questionLengthWords: Int = 0

    init(
        question: String,
        answer: String,
        isBlocked: Bool = false,
        complexityLevel: Int = 1,
        hasConnector: Bool = false,
        isFollowUp: Bool = false,
        questionLengthWords: Int = 0
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

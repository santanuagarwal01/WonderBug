//
//  HistoryItem.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 10/07/26.
//

import Foundation
import SwiftData

@Model
final class HistoryItem {
    
    @Attribute(.unique)
    var id: UUID
    
    var question: String
    var answer: String
    var isBlocked: Bool

    var createdAt: Date

    init(
        question: String,
        answer: String,
        isBlocked: Bool = false
    ) {
        self.id = UUID()
        self.question = question
        self.answer = answer
        self.isBlocked = isBlocked
        self.createdAt = Date()
    }
}

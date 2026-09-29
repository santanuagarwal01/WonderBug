//
//  HistoryRepository.swift
//  WonderBug
//

import Foundation
import SwiftData

/// Keeps SwiftData out of `HomeViewModel`. Reads happen in the views through `@Query`.
@MainActor
protocol HistoryRepositoryProtocol {
    func save(
        question: String,
        answer: String,
        isBlocked: Bool,
        complexityLevel: Int,
        hasConnector: Bool,
        isFollowUp: Bool,
        questionLengthWords: Int
    ) throws
}

@MainActor
final class HistoryRepository: HistoryRepositoryProtocol {

    /// Beyond this the oldest entries are deleted, so neither the store nor the History list grows
    /// without bound.
    private static let maxStoredItems = 700

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func save(
        question: String,
        answer: String,
        isBlocked: Bool,
        complexityLevel: Int,
        hasConnector: Bool,
        isFollowUp: Bool,
        questionLengthWords: Int
    ) throws {
        let item = HistoryItem(
            question: question,
            answer: answer,
            isBlocked: isBlocked,
            complexityLevel: complexityLevel,
            hasConnector: hasConnector,
            isFollowUp: isFollowUp,
            questionLengthWords: questionLengthWords
        )
        modelContext.insert(item)
        try modelContext.save()
        try trimToMaxStoredItems()
    }

    private func trimToMaxStoredItems() throws {
        let totalCount = try modelContext.fetchCount(FetchDescriptor<HistoryItem>())
        guard totalCount > Self.maxStoredItems else { return }

        var oldestFirst = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        oldestFirst.fetchLimit = totalCount - Self.maxStoredItems

        for item in try modelContext.fetch(oldestFirst) {
            modelContext.delete(item)
        }
        try modelContext.save()
    }
}

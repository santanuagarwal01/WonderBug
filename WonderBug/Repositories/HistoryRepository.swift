//
//  HistoryRepository.swift
//  WonderBug
//

import Foundation
import SwiftData

/// Abstraction over history persistence so `HomeViewModel` never touches SwiftData directly —
/// which also makes the view model testable with an in-memory fake.
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
    ) throws -> HistoryItem
}

/// SwiftData-backed implementation, writing through the `ModelContext` handed in from the
/// SwiftUI environment. Reads happen in the views themselves via live `@Query` bindings.
@MainActor
final class HistoryRepository: HistoryRepositoryProtocol {

    /// Hard cap on stored history. Beyond this, the oldest entries are deleted to keep both the
    /// database and the (eagerly-rendered, not lazy) History list from growing unbounded.
    private static let maxStoredItems = 700

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Persists one Q&A pair (blocked or answered), along with its Pattern Detection
    /// classification (spec §8), trims the oldest entries beyond `maxStoredItems`, and returns
    /// the inserted record.
    func save(
        question: String,
        answer: String,
        isBlocked: Bool = false,
        complexityLevel: Int,
        hasConnector: Bool,
        isFollowUp: Bool,
        questionLengthWords: Int
    ) throws -> HistoryItem {
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
        return item
    }

    /// Deletes the oldest entries once the store exceeds `maxStoredItems`. Uses `fetchCount` +
    /// a limited, ascending-date fetch rather than loading everything, so this stays cheap
    /// regardless of how large the store ever got before this cap was introduced.
    private func trimToMaxStoredItems() throws {
        let totalCount = try modelContext.fetchCount(FetchDescriptor<HistoryItem>())
        guard totalCount > Self.maxStoredItems else { return }

        var oldestFirst = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        oldestFirst.fetchLimit = totalCount - Self.maxStoredItems

        let overflow = try modelContext.fetch(oldestFirst)
        for item in overflow {
            modelContext.delete(item)
        }
        try modelContext.save()
    }
}

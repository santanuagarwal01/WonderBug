//
//  HistoryRepository.swift
//  WonderBug
//

import Foundation
import SwiftData

@MainActor
protocol HistoryRepositoryProtocol {
    func save(question: String, answer: String, isBlocked: Bool) throws -> HistoryItem
    func fetchAll() throws -> [HistoryItem]
    func fetchBlocked() throws -> [HistoryItem]
    func deleteAll() throws
}

@MainActor
final class HistoryRepository: HistoryRepositoryProtocol {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func save(question: String, answer: String, isBlocked: Bool = false) throws -> HistoryItem {
        let item = HistoryItem(question: question, answer: answer, isBlocked: isBlocked)
        modelContext.insert(item)
        try modelContext.save()
        return item
    }

    func fetchAll() throws -> [HistoryItem] {
        let descriptor = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func fetchBlocked() throws -> [HistoryItem] {
        let descriptor = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.isBlocked == true },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func deleteAll() throws {
        try modelContext.delete(model: HistoryItem.self)
        try modelContext.save()
    }
}

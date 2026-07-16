//
//  HistoryView.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 09/07/26.
//

import SwiftUI
import SwiftData

struct HistoryView: View {

    @Query(sort: \HistoryItem.createdAt, order: .reverse)
    private var historyItems: [HistoryItem]

    @Environment(\.modelContext) private var modelContext

    @State private var showBlockedOnly = false
    @State private var selectedItem: HistoryItem?
    @State private var showClearConfirmation = false

    private var filteredItems: [HistoryItem] {
        showBlockedOnly ? historyItems.filter(\.isBlocked) : historyItems
    }

    private var groupedItems: [(title: String, items: [HistoryItem])] {
        var result: [(title: String, items: [HistoryItem])] = []
        for item in filteredItems {
            let title = Self.sectionTitle(for: item.createdAt)
            if let lastIndex = result.indices.last, result[lastIndex].title == title {
                result[lastIndex].items.append(item)
            } else {
                result.append((title: title, items: [item]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            Image("wordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .padding(.top, 20)
            
            ScrollView {
                VStack(spacing: 20) {
                    
                    HStack {
                        Spacer()
                        Text("Question History")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(Color.wbTitle)
                        
                        Spacer()
                        
                        Button {
                            showClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.title3)
                                .foregroundColor(.gray)
                        }
                        .disabled(historyItems.isEmpty)
                    }
                    .padding(.top, 14)
                    
                    Button {
                        showBlockedOnly.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.wbBorder)
                                .clipShape(Circle())
                            
                            Text(showBlockedOnly ? "Show All" : "Show Flagged Only")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Color.wbTitle)
                        }
                    }
                    
                    if filteredItems.isEmpty {
                        ContentUnavailableView(
                            showBlockedOnly ? "No Flagged Questions" : "No Questions Yet",
                            systemImage: showBlockedOnly ? "checkmark.shield" : "leaf",
                            description: Text(
                                showBlockedOnly
                                ? "Nothing has been flagged so far."
                                : "Questions you ask will show up here."
                            )
                        )
                        .padding(.top, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groupedItems, id: \.title) { group in
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.gray)
                                    .padding(.top, 20)
                                    .padding(.bottom, 8)
                                
                                Divider()
                                
                                ForEach(group.items) { item in
                                    historyRow(for: item)
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Color.wbBackground)
        .navigationDestination(item: $selectedItem) { item in
            HistoryDetailView(item: item)
        }
        .alert(
            "Clear all history?",
            isPresented: $showClearConfirmation
        ) {
            Button("Clear History", role: .destructive) {
                clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all questions and answers.")
        }
    }

    @ViewBuilder
    private func historyRow(for item: HistoryItem) -> some View {
        Button {
            selectedItem = item
        } label: {
            HStack {
                if item.isBlocked {
                    Text("🚩")
                        .font(.body)
                }

                Text(item.question)
                    .font(.body)
                    .foregroundColor(Color.wbTitle)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private func clearHistory() {
        try? HistoryRepository(modelContext: modelContext).deleteAll()
    }

    private static func sectionTitle(for date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "TODAY"
        } else if calendar.isDateInYesterday(date) {
            return "YESTERDAY"
        }

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0

        if days < 7 {
            return "\(days) DAYS AGO"
        }

        return date.formatted(.dateTime.month(.abbreviated).day().year()).uppercased()
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: HistoryItem.self, inMemory: true)
}

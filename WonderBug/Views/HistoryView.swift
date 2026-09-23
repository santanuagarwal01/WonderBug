//
//  HistoryView.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 09/07/26.
//

import SwiftUI
import SwiftData

/// Parent-facing log of every question asked, grouped by day, with a toggle to show only
/// safety-flagged (🚩) questions for a quick review and each row tagged with its Pattern
/// Detection complexity level (L1-L4, spec §8). Rows navigate to `HistoryDetailView`.
struct HistoryView: View {

    @Query(sort: \HistoryItem.createdAt, order: .reverse)
    private var historyItems: [HistoryItem]

    @State private var showBlockedOnly = false
    @State private var selectedItem: HistoryItem?

    private var filteredItems: [HistoryItem] {
        showBlockedOnly ? historyItems.filter(\.isBlocked) : historyItems
    }

    /// Buckets the (already newest-first) items into day sections, preserving order — a simple
    /// single pass that appends to the current section while the title matches.
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
                    
                    Text("Question History")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(Color.wbTitle)
                        .frame(maxWidth: .infinity)
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
                        LazyVStack(alignment: .leading, spacing: 0) {
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
    }

    /// One tappable list row: the question text, prefixed with 🚩 when the item was blocked.
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

                Spacer(minLength: 8)

                Text("L\(item.complexityLevel)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Color.wbBorder)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.wbChip)
                    .clipShape(Capsule())
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    /// Human-friendly section label: "TODAY", "YESTERDAY", "N DAYS AGO" within a week,
    /// then an absolute date like "JUL 2, 2026".
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

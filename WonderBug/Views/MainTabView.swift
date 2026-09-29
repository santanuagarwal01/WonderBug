//
//  MainTabView.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 09/07/26.
//

import SwiftUI
import SwiftData

/// The app's shell: owns the shared `HomeViewModel` and swaps between Home, History and the current
/// answer under a custom tab bar. `AnswerView` is a content swap rather than a push so the tab bar
/// stays on screen.
struct MainTabView: View {

    enum Tab {
        case home
        case history
    }

    @State private var selectedTab: Tab = .home
    @StateObject private var homeViewModel = HomeViewModel(
        answerService: QwenAnswerService(),
        wikiSession: WikiSearchService.bundled().map(WikiSearchSession.init(service:))
    )
    @State private var answerData: AnswerData?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let answerData {
                    AnswerView(
                        question: answerData.question,
                        answer: answerData.answer,
                        viewModel: homeViewModel,
                        onAnswer: { self.answerData = $0 }
                    )
                } else {
                    switch selectedTab {
                    case .home:
                        HomeView(viewModel: homeViewModel, answerData: $answerData)
                    case .history:
                        HistoryView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            CustomTabBar(selectedTab: $selectedTab, onReselectHome: {
                // The way back from an answer to the starters and a fresh question.
                homeViewModel.clear()
                answerData = nil
            })
        }
        .onAppear {
            homeViewModel.configure(historyRepository: HistoryRepository(modelContext: modelContext))
        }
        .onChange(of: selectedTab) {
            answerData = nil
        }
    }
}

/// Two-icon tab bar, hand-rolled so it can stay visible under `AnswerView`.
private struct CustomTabBar: View {

    @Binding var selectedTab: MainTabView.Tab
    let onReselectHome: () -> Void

    var body: some View {
        HStack(spacing: 28) {
            Spacer()
            tabButton(tab: .home, systemImage: "house.fill")
            tabButton(tab: .history, systemImage: "clock.arrow.circlepath")
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24,
                style: .continuous
            )
            .fill(Color.wbBackground)
            .shadow(color: .black.opacity(0.08), radius: 8, y: -2)
            .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private func tabButton(tab: MainTabView.Tab, systemImage: String) -> some View {
        let isSelected = selectedTab == tab

        Button {
            if tab == .home && isSelected {
                onReselectHome()
            }
            selectedTab = tab
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(isSelected ? .white : .gray)
                .frame(width: 44, height: 44)
                .background(isSelected ? Color.wbBorder : Color.clear)
                .clipShape(Circle())
        }
    }
}

#Preview {
    MainTabView()
        .modelContainer(for: HistoryItem.self, inMemory: true)
}

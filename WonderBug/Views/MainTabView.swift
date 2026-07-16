//
//  MainTabView.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 09/07/26.
//

import SwiftUI
import SwiftData

struct MainTabView: View {

    enum Tab {
        case home
        case history
    }

    @State private var selectedTab: Tab = .home
    @StateObject private var homeViewModel = HomeViewModel(answerService: QwenAnswerService())
    @State private var answerData: AnswerData?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let answerData {
                    AnswerView(
                        question: answerData.question,
                        answer: answerData.answer,
                        isBlocked: answerData.isBlocked,
                        viewModel: homeViewModel,
                        onDismiss: { self.answerData = nil }
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

            CustomTabBar(selectedTab: $selectedTab)
        }
        .onAppear {
            homeViewModel.configure(historyRepository: HistoryRepository(modelContext: modelContext))
        }
        .onChange(of: selectedTab) {
            answerData = nil
        }
    }
}

private struct CustomTabBar: View {

    @Binding var selectedTab: MainTabView.Tab

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

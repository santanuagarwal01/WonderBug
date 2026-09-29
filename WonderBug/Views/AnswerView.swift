//
//  AnswerView.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 08/07/26.
//

import SwiftUI

/// One question and its answer, with "Read to me" and a bar for asking the next question in place.
/// Swapped in by `MainTabView` rather than pushed, so the tab bar stays visible; a new answer
/// replaces this one through `onAnswer`.
struct AnswerView: View {
    let question: String
    let answer: String
    @ObservedObject var viewModel: HomeViewModel
    let onAnswer: (AnswerData) -> Void
    @StateObject private var speechService = SpeechService()
    @State private var nextQuestion = ""
    @FocusState private var isQuestionFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image("wordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .padding(.vertical, 20)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .center, spacing: 20) {
                        Text("A CURIOUS BUG ASKED...")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.gray)
                            .padding(.top, 24)
                            .id(Self.top)

                        QuestionText(text: question)

                        ReadAloudButton(speechService: speechService, text: answer)
                            .padding(.top, 4)

                        AnswerText(text: answer)
                            .padding(.top, 12)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: question + answer) {
                    speechService.stop()
                    proxy.scrollTo(Self.top, anchor: .top)
                }
            }

            questionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.wbBackground)
        .onDisappear {
            speechService.stop()
        }
    }

    private static let top = "top"

    private var canAsk: Bool {
        !viewModel.isLoading && !nextQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The typed question is kept when the answer fails, so the child can tap send again.
    private var questionBar: some View {
        VStack(spacing: 8) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                TextField("Ask another question...", text: $nextQuestion)
                    .focused($isQuestionFocused)
                    .submitLabel(.send)
                    .onSubmit(ask)
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    .background(Color.white)
                    .overlay(Capsule().stroke(Color.wbBorder, lineWidth: 3))
                    .clipShape(Capsule())

                Button(action: ask) {
                    Group {
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image("send")
                                .resizable()
                                .renderingMode(.template)
                                .foregroundColor(.white)
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 18)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .background(Color.wbBorder.opacity(canAsk || viewModel.isLoading ? 1 : 0.5))
                    .clipShape(Circle())
                }
                .disabled(!canAsk)
                .accessibilityLabel("Ask")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    /// `clear()` first, so a failed answer can't leave the previous one to be shown under the new
    /// question.
    private func ask() {
        guard canAsk else { return }
        isQuestionFocused = false
        let typed = nextQuestion
        Task {
            viewModel.clear()
            viewModel.question = typed
            await viewModel.submit()
            if let shown = viewModel.shownAnswer {
                nextQuestion = ""
                onAnswer(shown)
            }
        }
    }
}

//
//  AnswerView.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 08/07/26.
//

import SwiftUI

/// Shows one question and its (possibly blocked) answer, with a text-to-speech "Read to me"
/// button. Displayed by `MainTabView` in place of the tab content — not pushed onto a navigation
/// stack — so the custom tab bar stays visible; "Ask another question" calls `onDismiss` to
/// return to `HomeView` with the session's follow-up context intact.
struct AnswerView: View {
    let question: String
    let answer: String
    let isBlocked: Bool
    @ObservedObject var viewModel: HomeViewModel
    let onDismiss: () -> Void
    @StateObject private var speechService = SpeechService()

    var body: some View {
        VStack(spacing: 20) {
            Image("wordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .padding(.vertical, 20)

            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    Text("A CURIOUS BUG ASKED...")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.gray)
                        .padding(.top, 24)

                    QuestionText(text: question)

                    Button {
                        speechService.toggle(answer)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: speechService.isSpeaking ? "pause.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.wbBorder)
                                .clipShape(Circle())

                            Text(speechService.isSpeaking ? "Reading..." : "Read to me")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Color.wbTitle)
                        }
                    }
                    .padding(.top, 4)

                    AnswerText(text: answer)
                        .padding(.top, 12)

                    Button {
                        viewModel.clear()
                        onDismiss()
                    } label: {
                        Text("Ask another question")
                            .font(.headline)
                            .foregroundColor(Color.wbTitle)
                            .frame(height: 52)
                            .padding(.horizontal, 28)
                            .background(Color.wbButton)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.wbBackground)
        .onDisappear {
            speechService.stop()
        }
    }
}

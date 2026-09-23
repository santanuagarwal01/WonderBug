//
//  HistoryDetailView.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 10/07/26.
//

import SwiftUI

/// Read-only view of one stored history entry (question, answer, blocked badge if flagged),
/// with the same "Read to me" playback as `AnswerView`. Reached by tapping a row in
/// `HistoryView` via a real navigation push, hence the custom back button.
struct HistoryDetailView: View {

    let item: HistoryItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speechService = SpeechService()
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Image("wordmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 32)

                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.title2.weight(.medium))
                            .foregroundColor(.gray)
                            .frame(width: 48, height: 48)
                            .background(Color.wbChip)
                            .clipShape(Circle())
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            ScrollView {
                VStack(spacing: 20) {
                    Text("YOU ASKED...")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.gray)
                        .padding(.top, 20)

                    QuestionText(text: item.question)

                    Button {
                        speechService.toggle(item.answer)
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

                    AnswerText(text: item.answer)
                        .padding(.top, 12)

                    if item.isBlocked {
                        BlockedBadge()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.wbBackground)
        .navigationBarBackButtonHidden()
        .onDisappear {
            speechService.stop()
        }
    }
}

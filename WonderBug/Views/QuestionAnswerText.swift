//
//  QuestionAnswerText.swift
//  WonderBug
//

import SwiftUI

/// Question and answer pieces shared by `AnswerView` and `HistoryDetailView`.
struct QuestionText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 26, weight: .bold))
            .foregroundColor(Color.wbTitle)
            .multilineTextAlignment(.center)
    }
}

struct AnswerText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .regular))
            .foregroundColor(Color.wbTitle)
            .multilineTextAlignment(.center)
            .lineSpacing(6)
    }
}

/// "Read to me": starts reading the text aloud, or stops it.
struct ReadAloudButton: View {
    @ObservedObject var speechService: SpeechService
    let text: String

    var body: some View {
        Button {
            speechService.toggle(text)
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
    }
}

/// Shown under answers whose question the safety gate refused.
struct BlockedBadge: View {
    var body: some View {
        Text("🚩 This question was blocked")
            .font(.footnote)
            .foregroundStyle(.red)
    }
}

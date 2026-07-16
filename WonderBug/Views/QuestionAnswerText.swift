//
//  QuestionAnswerText.swift
//  WonderBug
//

import SwiftUI

/// Shared question/answer typography for AnswerView and HistoryDetailView, kept as small
/// individual pieces (rather than one combined block) since AnswerView places its "Read to me"
/// button between the question and the answer.
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

struct BlockedBadge: View {
    var body: some View {
        Text("🚩 This question was blocked")
            .font(.footnote)
            .foregroundStyle(.red)
    }
}

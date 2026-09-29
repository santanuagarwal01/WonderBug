//
//  AnswerCleanup.swift
//  WonderBug
//

import Foundation

/// Turns the model's raw output into the answer a child sees. Kept apart from `QwenAnswerService`,
/// which needs MLX, so it can be run on a Mac (Tools/WikiEval/llm).
enum AnswerCleanup {

    static func clean(_ raw: String) -> String {
        removingEmoji(trimToCompleteSentence(firstLine(of: stripThinkingBlock(from: raw))))
    }

    /// Even with thinking disabled the model may emit a `<think>` block. An unclosed one means there
    /// is no answer at all, so everything from it on is dropped and the caller sees an empty answer.
    private static func stripThinkingBlock(from raw: String) -> String {
        var text = raw
        if let start = text.range(of: "<think>") {
            if let end = text.range(of: "</think>") {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// With a passage in the prompt the model often finishes, then starts again on a new line that
    /// restates the answer and sometimes contradicts it ("No. Spiders have eight legs." then "Yes,
    /// spiders have eight legs."), so only the first line is kept.
    private static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Drops a half-finished last sentence left by the token cap. Only text ending on a letter or
    /// digit counts as cut off, and text with no earlier sentence break is returned as it is.
    private static func trimToCompleteSentence(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        guard let lastTerminator = text.lastIndex(where: { ".!?".contains($0) }) else { return text }
        return String(text[...lastTerminator]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes emoji: the model's, since the app picks its own (`TopicEmoji`), and the app's before
    /// an answer is read aloud. Digits, "#" and "*" also carry Unicode's emoji property, so only
    /// pictographs above U+2000 go. In `clean` this runs after `trimToCompleteSentence`, which relies
    /// on a trailing emoji to tell a finished answer from one cut off mid-word.
    static func removingEmoji(_ text: String) -> String {
        let kept = text.filter { character in
            !character.unicodeScalars.contains {
                $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)
            }
        }
        return kept.split(separator: " ").joined(separator: " ")
    }
}

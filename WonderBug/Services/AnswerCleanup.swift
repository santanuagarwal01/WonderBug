//
//  AnswerCleanup.swift
//  WonderBug
//

import Foundation

/// Turns the model's raw output into the answer a child sees. Kept apart from `QwenAnswerService`,
/// which needs MLX, so the cleanup can be checked on a Mac against real device answers.
enum AnswerCleanup {

    static func clean(_ raw: String) -> String {
        removingEmoji(trimToCompleteSentence(firstLine(of: stripThinkingBlock(from: raw))))
    }

    /// Defensive cleanup: even with thinking disabled, the model may emit an (empty or non-empty)
    /// `<think>…</think>` block before the answer. Strip it — and if generation was cut off before
    /// the block closed, there is no answer at all, so return empty and let the caller's
    /// error/empty handling kick in rather than showing a child raw chain-of-thought.
    static func stripThinkingBlock(from raw: String) -> String {
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

    /// Keeps only the first line. With a Wikipedia passage in the prompt, the model often finishes
    /// its answer and then starts again on a new line that restates it, usually opening "Yes," and
    /// sometimes contradicting itself ("No. Spiders have eight legs." then "Yes, spiders have eight
    /// legs."). An answer is one or two sentences, so any line break marks that restart.
    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Drops a trailing half-finished sentence left behind when generation stops at the token cap,
    /// so a child is never shown an answer that ends mid-word. Only text ending on a letter or digit
    /// is treated as cut off — an answer already ending in punctuation or an emoji is left alone,
    /// and one with no sentence break to fall back to is returned as-is rather than emptied.
    static func trimToCompleteSentence(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        guard let lastTerminator = text.lastIndex(where: { ".!?".contains($0) }) else { return text }
        return String(text[...lastTerminator]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes any emoji the model writes despite being told not to; the app picks its own (see
    /// `TopicEmoji`). Digits, "#", "*" and "©" also carry Unicode's emoji property, so only
    /// pictographs above U+2000 are removed. Runs after `trimToCompleteSentence`, which relies on
    /// a trailing emoji to tell a finished answer from one cut off mid-word.
    static func removingEmoji(_ text: String) -> String {
        let kept = text.filter { character in
            !character.unicodeScalars.contains {
                $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)
            }
        }
        return kept.split(separator: " ").joined(separator: " ")
    }
}

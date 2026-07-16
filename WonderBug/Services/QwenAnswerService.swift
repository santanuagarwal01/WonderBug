//
//  QwenAnswerService.swift
//  WonderBug
//

import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// Runs Qwen3-0.6B fully on-device via MLX Swift — no network access, ever.
/// The model's files are bundled directly in the app (added as a synchronized group named
/// "Qwen3-0.6B-4bit"), so the app works completely offline from first launch, per spec.
///
/// NOTE: Xcode's synchronized-group mechanism flattens the model's files (config.json,
/// model.safetensors, tokenizer.json, etc.) directly into the app bundle's top level rather than
/// preserving them under a nested subfolder — confirmed by inspecting an actual build product.
/// That's why the model directory below is `Bundle.main.bundleURL` itself.
final class QwenAnswerService: AnswerServicing {

    private static let systemPrompt = """
    You are WonderBug, a friendly encyclopedia for children ages 4-8. Answer every question in 2-3 \
    short, simple sentences a young child can understand. Be factual and always positive — never \
    criticize or judge. You may include one or two child-appropriate emoji. Never mention that you \
    are an AI, a language model, or a computer program. Never ask the user questions back.
    """

    /// Loaded lazily on first use and reused after that — loading the model is expensive
    /// (reading ~335MB of weights), running it for every question would be far too slow.
    private var cachedContainer: ModelContainer?

    func generateAnswer(for question: String, context: [AnswerData]) async throws -> String {
        let container = try await loadedContainer()

        let messages = Self.buildChat(question: question, context: context)
        // Qwen3 is a hybrid "thinking" model — without this flag its chat template lets it emit a
        // long <think>…</think> reasoning block before the answer, burning the whole token budget.
        let input = try await container.prepare(
            input: UserInput(chat: messages, additionalContext: ["enable_thinking": false])
        )

        var result = ""
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(maxTokens: 150)
        )

        for await event in stream {
            if case .chunk(let text) = event {
                result += text
            }
        }

        return Self.stripThinkingBlock(from: result)
    }

    private func loadedContainer() async throws -> ModelContainer {
        if let cachedContainer {
            return cachedContainer
        }

        let container = try await loadModelContainer(
            from: Bundle.main.bundleURL,
            using: #huggingFaceTokenizerLoader()
        )
        cachedContainer = container
        return container
    }

    /// Defensive cleanup: even with thinking disabled, the model may emit an (empty or non-empty)
    /// `<think>…</think>` block before the answer. Strip it — and if generation was cut off before
    /// the block closed, there is no answer at all, so return empty and let the caller's
    /// error/empty handling kick in rather than showing a child raw chain-of-thought.
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

    private static func buildChat(question: String, context: [AnswerData]) -> [Chat.Message] {
        var messages: [Chat.Message] = [.system(systemPrompt)]

        for turn in context.suffix(3) {
            messages.append(.user(turn.question))
            messages.append(.assistant(turn.answer))
        }

        messages.append(.user(question))
        return messages
    }
}

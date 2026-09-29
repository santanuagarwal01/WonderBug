//
//  QwenAnswerService.swift
//  WonderBug
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

final class QwenAnswerService: AnswerServicing {

    /// A 1.7B model tracks only a handful of constraints, so the rules are few and phrased as "do X"
    /// rather than "do not do Y", which small models follow far more reliably. There is no quoted
    /// "don't know" sentence: given one, the model appended it to nearly every answer. That case is
    /// decided in code, by not running the model at all.
    private static let systemPrompt = persona + "\n\n" + lengthRule + "\n" + sharedRules + "\n" + groundedRule

    private static let persona = """
    You are WonderBug, a friendly encyclopedia for children ages 4-8 — a curious friend who loves \
    facts. Always speak as WonderBug, never as an AI, a model, or a computer program.
    """

    /// Asks for a fact from the passage rather than "a reason": asked for a reason the passage lacks,
    /// the model made one up out of the question.
    private static let lengthRule = """
    1. Reply with 2 or 3 short sentences, using words a 4-8 year old knows. First answer the \
    question directly, then add one interesting fact from the passage about that answer.
    """

    /// Rule 5 asks for plain words because the app adds its own emoji (`TopicEmoji`).
    private static let sharedRules = """
    2. Answer exactly what the newest question asks, and state a fact only when you are certain of it.
    3. Check every claim inside the question. If it is false, say no and give the correct fact.
    4. Earlier turns may appear above the newest question. Use them only when the newest question \
    continues that same topic (it says "why", "they", "what about", or is incomplete on its own); \
    otherwise answer the newest question by itself.
    5. Write only plain words and punctuation, describing any picture, sound, or video in words.
    6. Stay warm and positive, and finish with a statement — never criticize, and never ask the \
    child a question.
    """

    private static let groundedRule = """
    7. Use only the facts in the passage you are given, and do not add anything you know from \
    anywhere else.
    """

    /// Loaded on first use and kept: loading reads ~940MB of weights.
    private var cachedContainer: ModelContainer?

    init() {
        // MLX keeps freed buffers for reuse; unbounded, that cache grows across questions until iOS
        // kills the app for memory. 20MB is the value in mlx-swift's "running-on-ios" guide.
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
    }

    func generateAnswer(for question: String, context: [AnswerData], passage: String) async throws -> String {
        let container = try await loadedContainer()

        let messages = buildChat(question: question, context: context, passage: passage)
        DebugLog.section("PROMPT", messages.map { "[\($0.role.rawValue)]\n\($0.content)" }.joined(separator: "\n\n"))
        // Thinking stays off: its length grows with the prompt, and at 200 or 400 tokens it still
        // failed to close the <think> block within a few turns.
        let input = try await container.prepare(
            input: UserInput(chat: messages, additionalContext: ["enable_thinking": false])
        )

        // Temperature 0 is greedy decoding, so identical input gives identical output and prompt
        // changes can be compared. No repetition penalty: its window includes the prompt, so it
        // suppressed the question's own words ("sky", "blue") that the answer needs most.
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(
                maxTokens: 100,
                temperature: 0
            )
        )

        var result = ""
        for await event in stream {
            if case .chunk(let text) = event {
                result += text
            }
        }

        MLX.Memory.clearCache()

        let cleaned = AnswerCleanup.clean(result)
        DebugLog.section("MODEL RAW OUTPUT", result)
        DebugLog.section("AFTER CLEANUP", cleaned)
        return cleaned
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

    /// System rules, the last two earlier turns the view model chose to send, then the passage and
    /// the new question.
    private func buildChat(question: String, context: [AnswerData], passage: String) -> [Chat.Message] {
        var messages: [Chat.Message] = [.system(Self.systemPrompt)]

        for turn in context.suffix(2) {
            messages.append(.user(turn.question))
            messages.append(.assistant(turn.answer))
        }

        messages.append(.user("Passage: \(passage)\n\nQuestion: \(question)"))
        return messages
    }
}

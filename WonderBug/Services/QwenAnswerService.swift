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

    /// Six grouped rules rather than the seventeen this started as. A 1.7B model tracks only a
    /// handful of constraints before it begins dropping them at random, so redundant rules were
    /// merged and each is phrased as an instruction to follow rather than a prohibition — small
    /// models comply with "do X" far more reliably than with "do not do Y".
    ///
    /// Deliberately contains no quoted fallback sentence (such as a "find out with a grown-up" line).
    /// Given one verbatim, the model appended it to nearly every answer, right or wrong, instead of
    /// using it only when unsure — it cannot tell when it doesn't know something.
    private static let systemPrompt = persona + "\n\n" + lengthRule + "\n" + sharedRules

    /// Used whenever a Wikipedia passage is supplied. The extra sentences must be facts from the
    /// passage rather than "a reason": asked for a reason the passage doesn't contain, the model made
    /// one up out of the question ("Mercury is the smallest planet because it is the smallest in
    /// size"). A "1 or 2 sentences, 24 words" limit was tried too, and gave bare one-line answers
    /// ("Yes, frogs can jump."). Rule 7 confines it to the passage and, like `systemPrompt`, quotes no
    /// "don't know" sentence — that case is decided in code, by not running the model at all.
    private static let groundedSystemPrompt =
        persona + "\n\n" + groundedLengthRule + "\n" + sharedRules + "\n" + groundedRule

    private static let persona = """
    You are WonderBug, a friendly encyclopedia for children ages 4-8 — a curious friend who loves \
    facts. Always speak as WonderBug, never as an AI, a model, or a computer program.
    """

    private static let lengthRule = """
    1. Reply with exactly 2 short sentences, 12-24 words in total, using words a 4-8 year old \
    knows. First answer the question directly, then give one simple reason or detail about that answer.
    """

    private static let groundedLengthRule = """
    1. Reply with 2 or 3 short sentences, using words a 4-8 year old knows. First answer the \
    question directly, then add one interesting fact from the passage about that answer.
    """

    /// Rule 5 asks for plain words because the app adds its own emoji from a keyword list
    /// (`TopicEmoji`); the model's own choices were often wrong.
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

    /// Loaded lazily on first use and reused after that — loading the model is expensive
    /// (reading ~940MB of weights), running it for every question would be far too slow.
    private var cachedContainer: ModelContainer?

    init() {
        // MLX recycles the temporary buffers each generate() call produces rather than freeing
        // them immediately (for performance) — left unconstrained, this cache grows without bound
        // across repeated questions until iOS's jetsam killer terminates the app for memory use.
        // 20MB matches Apple's own documented example for LLM inference on memory-limited devices.
        // See mlx-swift's "running-on-ios" guide.
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
    }

    /// Builds a chat prompt (system rules + optional prior turns + the new question), runs the
    /// model, and returns the cleaned answer text.
    func generateAnswer(for question: String, context: [AnswerData], passage: String?) async throws -> String {
        let container = try await loadedContainer()

        let messages = buildChat(question: question, context: context, passage: passage)
        DebugLog.section("PROMPT", messages.map { "[\($0.role.rawValue)]\n\($0.content)" }.joined(separator: "\n\n"))
        // Qwen3 is a hybrid "thinking" model — without this flag its chat template lets it emit a
        // <think>…</think> reasoning block before the answer. Tried enabling it (hoping reasoning
        // would help the false-premise rules below), but its length scales with how much context is
        // in the prompt rather than converging to something stable: at maxTokens 200 it failed by
        // turn 2 (never closed the block), at 400 by turn 6 — doubling the budget only delayed the
        // same failure, it didn't fix it. Reverted to disabled: this is the known-stable config.
        let input = try await container.prepare(
            input: UserInput(chat: messages, additionalContext: ["enable_thinking": false])
        )

        var result = ""
        // temperature 0 selects `ArgMaxSampler`, making generation deterministic: a factual lookup
        // has one best answer, and identical input now yields identical output, so a prompt change
        // can actually be A/B tested instead of being judged against a moving baseline.
        //
        // repetitionPenalty is deliberately omitted. `RepetitionContext` seeds its window from the
        // prompt, not just from generated tokens, keeping the last `repetitionContextSize` of it —
        // so the previous 1.15/256 pairing was penalising the child's own question words (asked
        // "why is the sky blue", the answer needed "sky" and "blue" most and they were the tokens
        // suppressed) along with the prior turn's topic noun that a follow-up depends on.
        //
        // maxTokens 100 gives the 12-24 word rule room to finish its last sentence instead of being
        // cut mid-word at the cap; anything still unterminated is trimmed after generation.
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(
                maxTokens: 100,
                temperature: 0
            )
        )

        for await event in stream {
            if case .chunk(let text) = event {
                result += text
            }
        }

        // Proactively release recycled buffers now rather than waiting for the cache limit to be
        // hit on some later allocation — keeps resident memory flat between questions.
        MLX.Memory.clearCache()

        let cleaned = AnswerCleanup.clean(result)
        DebugLog.section("MODEL RAW OUTPUT", result)
        DebugLog.section("AFTER CLEANUP", cleaned)
        return cleaned
    }

    /// Returns the cached model, loading it from the app bundle on first call.
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

    /// Assembles the chat-message array the model is prompted with: system rules, then up to 2
    /// prior turns, then the new question.
    ///
    /// Prior turns are always included now rather than gated behind a heuristic guess at whether
    /// the new question "looks like" a follow-up — that heuristic (matching a small fixed set of
    /// pronouns like "they"/"it"/"there") had real false negatives (e.g. "Like which planets",
    /// which depends entirely on the previous answer but contains none of those words) and false
    /// positives (e.g. "Is there life on any other planet", where "there" is existential, not a
    /// reference, and prior turns were needlessly injected). Relevance is instead handled by the
    /// system prompt explicitly instructing the model when to use vs. ignore this context — turns
    /// are capped at 2 rather than the previous 3 to bound the extra prompt length this costs.
    private func buildChat(question: String, context: [AnswerData], passage: String?) -> [Chat.Message] {
        var messages: [Chat.Message] = [.system(passage == nil ? Self.systemPrompt : Self.groundedSystemPrompt)]

        for turn in context.suffix(2) {
            messages.append(.user(turn.question))
            messages.append(.assistant(turn.answer))
        }

        if let passage {
            messages.append(.user("Passage: \(passage)\n\nQuestion: \(question)"))
        } else {
            messages.append(.user(question))
        }
        return messages
    }
}

//
//  SpeechService.swift
//  WonderBug
//

import Foundation
import AVFoundation
import Combine

/// Reads an answer aloud entirely on-device via AVSpeechSynthesizer — no network, no Qwen dependency.
@MainActor
final class SpeechService: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Single entry point for the "Read to me" button: starts reading, or stops if already reading.
    func toggle(_ text: String) {
        if isSpeaking {
            stop()
        } else {
            speak(text)
        }
    }

    // Tunables for the reading voice: slightly slowed and slightly brighter than default,
    // aimed at young listeners. Rate is a multiplier on the system default; pitch 1.0 is neutral.
    private static let speechRateMultiplier: Float = 0.9
    private static let pitchMultiplier: Float = 1.1

    /// Speaks the text in the Samantha voice, slightly slowed and pitched up for young listeners.
    /// Emoji are stripped first — the synthesizer would otherwise read them out as descriptions
    /// ("frog face", "sparkles"), which sounds odd mid-answer.
    func speak(_ text: String) {
        let spokenText = Self.strippingEmoji(from: text)
        guard !spokenText.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = Self.samanthaVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Self.speechRateMultiplier
        utterance.pitchMultiplier = Self.pitchMultiplier
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    /// Returns Samantha (en-US) in the best installed quality — premium/enhanced if the user has
    /// downloaded one, otherwise the built-in compact version. Falls back to the default en-US
    /// voice in the unlikely case no Samantha variant is present.
    private static func samanthaVoice() -> AVSpeechSynthesisVoice? {
        let samanthas = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.name.hasPrefix("Samantha") }

        let ranked = samanthas.sorted { $0.quality.rawValue > $1.quality.rawValue }
        return ranked.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Removes emoji (including multi-scalar sequences like flags and 👩‍🚀) while keeping normal
    /// text intact. The `value > 0x238C` guard matters: plain digits and symbols like "1" or "#"
    /// technically carry the `isEmoji` property, and must not be stripped from spoken answers.
    private static func strippingEmoji(from text: String) -> String {
        let cleaned = text.filter { character in
            guard let scalar = character.unicodeScalars.first else { return true }
            let isEmoji = scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x238C)
            return !isEmoji
        }
        return cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Halts playback immediately — also called from `onDisappear` so audio never outlives its screen.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

/// Keeps `isSpeaking` accurate when playback ends on its own (finished or cancelled), so the
/// play/pause button resets without user action.
extension SpeechService: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
        }
    }
}

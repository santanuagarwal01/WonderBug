//
//  SpeechService.swift
//  WonderBug
//

import Foundation
import AVFoundation
import Combine

/// Reads an answer aloud on-device with AVSpeechSynthesizer.
@MainActor
final class SpeechService: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    /// Slightly slower and brighter than the default voice, for young listeners.
    private static let speechRateMultiplier: Float = 0.9
    private static let pitchMultiplier: Float = 1.1

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String) {
        if isSpeaking {
            stop()
        } else {
            speak(text)
        }
    }

    /// Emoji are removed first, or the synthesizer reads them out ("frog face").
    private func speak(_ text: String) {
        let spokenText = AnswerCleanup.removingEmoji(text)
        guard !spokenText.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = Self.samanthaVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Self.speechRateMultiplier
        utterance.pitchMultiplier = Self.pitchMultiplier
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    /// Samantha (en-US) in the best installed quality, or the default en-US voice.
    private static func samanthaVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.name.hasPrefix("Samantha") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

/// Resets `isSpeaking` when playback ends on its own.
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

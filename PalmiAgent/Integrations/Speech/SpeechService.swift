import AVFoundation
import Foundation
import Speech

struct SpeechPermissionSnapshot: Sendable {
    let microphoneGranted: Bool
    let speechStatus: SFSpeechRecognizerAuthorizationStatus
}

@MainActor
final class SpeechService {
    private let synthesizer = AVSpeechSynthesizer()

    func requestPermissions() async -> SpeechPermissionSnapshot {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        let microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                continuation.resume(returning: granted)
            })
        }

        return SpeechPermissionSnapshot(microphoneGranted: microphoneGranted, speechStatus: speechStatus)
    }

    func speakDefaultText() {
        speak(text: "你好，我是 PalmiAgent。语音朗读链路已经接通。", language: "zh-CN", rate: 0.46)
    }

    func speak(
        text: String,
        language: String?,
        rate: Float?,
        pitch: Float? = nil,
        volume: Float? = nil,
        preUtteranceDelay: TimeInterval? = nil,
        postUtteranceDelay: TimeInterval? = nil,
        voiceIdentifier: String? = nil,
        queueBehavior: String? = nil
    ) {
        let queueBehavior = queueBehavior?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "append"
        switch queueBehavior {
        case "interrupt", "replace":
            synthesizer.stopSpeaking(at: .immediate)
        case "pause":
            _ = synthesizer.pauseSpeaking(at: .immediate)
        default:
            break
        }

        let utterance = AVSpeechUtterance(string: text)
        if let voiceIdentifier, !voiceIdentifier.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        } else if let language, !language.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = min(max(rate ?? 0.46, 0.1), 0.6)
        utterance.pitchMultiplier = min(max(pitch ?? 1.0, 0.5), 2.0)
        utterance.volume = min(max(volume ?? 1.0, 0.0), 1.0)
        utterance.preUtteranceDelay = max(0, preUtteranceDelay ?? 0)
        utterance.postUtteranceDelay = max(0, postUtteranceDelay ?? 0)
        synthesizer.speak(utterance)
    }

    func stop(boundary: String?) -> Bool {
        synthesizer.stopSpeaking(at: speechBoundary(for: boundary))
    }

    func pause(boundary: String?) -> Bool {
        synthesizer.pauseSpeaking(at: speechBoundary(for: boundary))
    }

    func `continue`() -> Bool {
        synthesizer.continueSpeaking()
    }

    private func speechBoundary(for rawValue: String?) -> AVSpeechBoundary {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "word":
            return .word
        default:
            return .immediate
        }
    }
}

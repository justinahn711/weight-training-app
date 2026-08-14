//
//  VoiceRecognizer.swift
//  ChickenBreast
//

import AVFoundation
import Observation
import Speech
import WeightTrainingCore

/// On-device speech recognition for hands-free logging (#21).
///
/// `requiresOnDeviceRecognition` is set unconditionally, and the recognizer
/// refuses to start without it. Gyms are basements — this has to work with no
/// signal, and audio from a session shouldn't be leaving the phone regardless.
///
/// The recognizer only ever produces a `VoiceParse`. Deciding whether that
/// becomes a logged set is the snap-and-confirm flow in #22, so a mis-hear can
/// never write anything on its own.
@MainActor
@Observable
final class VoiceRecognizer {

    enum State: Equatable {
        case idle
        case unavailable(String)
        case listening
    }

    private(set) var state: State = .idle

    /// What's been heard so far, shown live so it's obvious when the recogniser
    /// has misheard and the phrase is worth repeating.
    private(set) var transcript: String = ""

    /// The most recent thing understood, or nil when nothing has parsed yet.
    private(set) var parsed: VoiceParse?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isListening: Bool { state == .listening }

    // MARK: - Permissions

    /// Asks for both permissions. Declining either is remembered by the system,
    /// so this is safe to call whenever the microphone is tapped.
    func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            state = .unavailable("Speech recognition is off in Settings.")
            return false
        }

        let microphone = await AVAudioApplication.requestRecordPermission()
        guard microphone else {
            state = .unavailable("Microphone access is off in Settings.")
            return false
        }
        return true
    }

    // MARK: - Listening

    func start() async {
        guard !isListening else { return }
        guard await requestAccess() else { return }

        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("Speech recognition isn't available right now.")
            return
        }
        // No fallback to servers: if the model isn't downloaded, say so rather
        // than quietly sending gym audio to Apple.
        guard recognizer.supportsOnDeviceRecognition else {
            state = .unavailable("On-device speech isn't ready on this phone yet.")
            return
        }

        do {
            try configureAudioSession()
        } catch {
            state = .unavailable("Couldn't start the microphone.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        // A closed grammar's vocabulary, given to the recogniser as a hint. It
        // biases toward words that mean something here, which matters when the
        // competing sound is a dropped plate.
        request.contextualStrings = [
            "reps", "rpe", "same", "next", "add", "drop", "timer", "note",
        ]
        self.request = request

        transcript = ""
        parsed = nil
        state = .listening

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            state = .unavailable("Couldn't start the microphone.")
            stop()
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.parsed = VoiceGrammar.parse(self.transcript)
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if case .listening = state { state = .idle }
    }

    /// Clears the last understood command once it's been acted on, so it can't
    /// be applied twice.
    func consume() {
        parsed = nil
        transcript = ""
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .duckOthers rather than interrupting: people lift to music, and
        // stopping it to log a set is its own kind of rude.
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}

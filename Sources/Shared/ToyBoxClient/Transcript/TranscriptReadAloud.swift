import AVFoundation
import ToyBoxKit
import Observation
import OSLog

/// Reads a pending request aloud, one at a time across the app, so a new request replaces the one
/// being read. The card and the transcript show Stop for the same request, since both ask this one
/// reader by its channel and sequence.
@MainActor @Observable public final class TranscriptReadAloud {
    public static let shared = TranscriptReadAloud()

    public struct Request: Equatable, Sendable {
        public let channelID: String
        public let sequence: Int
        /// The request's Markdown, read as plain text.
        public let text: String

        public init(channelID: String, sequence: Int, text: String) {
            self.channelID = channelID
            self.sequence = sequence
            self.text = text
        }

        func isSame(as other: Request) -> Bool { channelID == other.channelID && sequence == other.sequence }
    }

    public private(set) var reading: Request?
    /// Dictation is listening, so Read Aloud waits rather than speak into the microphone.
    public private(set) var isMicrophoneOpen = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let delegate = Delegate()
    @ObservationIgnored private var utterance: AVSpeechUtterance?
    /// Whether the audio session goes back to other apps once a stopped reading ends. Dictation stops
    /// the reader as it takes the session for the microphone, so it keeps it.
    @ObservationIgnored private var releasesAudio = true

    private init() {
        synthesizer.delegate = delegate
        delegate.ended = { [weak self] in self?.ended($0) }
    }

    public func isReading(_ request: Request) -> Bool { reading?.isSame(as: request) == true }

    public func toggle(_ request: Request) {
        if isReading(request) { stop() } else { read(request) }
    }

    public func read(_ request: Request) {
        let utterance = AVSpeechUtterance(string: MarkdownBlock.plainText(request.text))
        // Spoken Content's voice and rate, when the user has chosen them.
        utterance.prefersAssistiveTechnologySettings = true
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: .interruptSpokenAudioAndMixWithOthers)
            try session.setActive(true)
        } catch {
            Self.logger.error("Read Aloud audio session could not activate: \(error.localizedDescription)")
        }
        #endif
        self.utterance = utterance
        reading = request
        releasesAudio = true
        synthesizer.speak(utterance)
    }

    /// Stops reading `request`, if it's the one being read.
    public func stop(_ request: Request) {
        if isReading(request) { stop() }
    }

    /// Stops reading. `releasingAudio` is false when the caller is taking the audio session itself.
    public func stop(releasingAudio: Bool = true) {
        guard reading != nil else { return }
        utterance = nil
        reading = nil
        releasesAudio = releasingAudio
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// A reading finished or was cancelled. Only the current one, or a stop with nothing after it,
    /// gives the session back, so a replaced reading's late cancel leaves its successor speaking.
    private func ended(_ ended: AVSpeechUtterance) {
        if ended === utterance {
            utterance = nil
            reading = nil
        } else if utterance != nil || !releasesAudio {
            return
        }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.error("Read Aloud audio session could not deactivate: \(error.localizedDescription)")
        }
        #endif
    }

    /// Dictation's microphone, which stops reading as it opens and holds Read Aloud off until it closes.
    /// `releasingAudio` is false when the source takes the audio session itself. Dictation starts and
    /// stops its source on the main actor.
    package final class Microphone: DictationAudioSource, @unchecked Sendable {
        private let source: DictationAudioSource
        private let releasesAudio: Bool

        package init(_ source: DictationAudioSource, releasingAudio: Bool = true) {
            self.source = source
            releasesAudio = releasingAudio
        }

        package func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
            MainActor.assumeIsolated {
                TranscriptReadAloud.shared.stop(releasingAudio: releasesAudio)
                TranscriptReadAloud.shared.isMicrophoneOpen = true
            }
            do {
                try source.start(format: format, handler: handler)
            } catch {
                MainActor.assumeIsolated { TranscriptReadAloud.shared.isMicrophoneOpen = false }
                throw error
            }
        }

        package func stop() {
            source.stop()
            MainActor.assumeIsolated { TranscriptReadAloud.shared.isMicrophoneOpen = false }
        }
    }

    private static let logger = Logger(subsystem: "dev.toybox", category: "ReadAloud")

    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        @MainActor var ended: (AVSpeechUtterance) -> Void = { _ in }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                           didFinish utterance: AVSpeechUtterance) {
            end(utterance)
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                           didCancel utterance: AVSpeechUtterance) {
            end(utterance)
        }

        private nonisolated func end(_ utterance: AVSpeechUtterance) {
            // Only its identity is read, and it's never changed once spoken.
            nonisolated(unsafe) let utterance = utterance
            Task { @MainActor in ended(utterance) }
        }
    }
}

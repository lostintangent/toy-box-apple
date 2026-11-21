import AVFoundation
import Foundation
import OSLog
import Speech

package enum DictationAudioEvent: Sendable {
    case audio(AnalyzerInput, level: Double)
    case unavailable
}

/// Feeds analyzer-format audio to a dictation session. Tests and checks feed recorded files through
/// the same real `DictationTranscriber` the microphone uses.
package protocol DictationAudioSource: AnyObject {
    /// Returns once audio flows, without holding the main thread while the microphone wakes.
    @MainActor func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) async throws
    /// Returns once audio has stopped.
    @MainActor func stop() async
}

enum DictationError: LocalizedError {
    case microphoneUnavailable
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "The microphone is unavailable."
        case .unsupportedAudioFormat: "The microphone's audio format is not supported."
        }
    }
}

/// Captures the default input device with `AVAudioEngine`. Waking Core Audio can take seconds on a
/// process's first start, so every microphone does its audio work on one queue, off the main thread,
/// in the order it was asked for. Each stop finishes before the next start, even across notes.
package final class MicrophoneDictationSource: DictationAudioSource, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "dev.toybox.dictation.microphone", qos: .userInitiated)
    private static let logger = Logger(subsystem: "dev.toybox", category: "Dictation")
    // Everything below is touched only on `queue`.
    private lazy var engine = AVAudioEngine()
    private var observers: [any NSObjectProtocol] = []
    private var isRunning = false
    #if os(iOS)
    private var isSessionActive = false
    #endif

    package init() {}

    @MainActor
    package func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Self.queue.async { [self] in
                do {
                    try open(format: format, handler: handler)
                    continuation.resume()
                } catch {
                    close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    package func stop() async {
        await withCheckedContinuation { continuation in
            Self.queue.async { [self] in
                close()
                continuation.resume()
            }
        }
    }

    private func open(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
        let center = NotificationCenter.default
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)
        isSessionActive = true
        observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification,
                                            object: session, queue: nil) { _ in handler(.unavailable) })
        #endif
        try capture(format: format, handler: handler)
        // The engine stops when the input device changes. Follow a switch, and report a device that's gone.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: nil) { [weak self] _ in
            Self.queue.async { [weak self] in
                guard let self, isRunning else { return }
                do {
                    try capture(format: format, handler: handler)
                } catch {
                    close()
                    handler(.unavailable)
                }
            }
        })
    }

    private func capture(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let natural = input.outputFormat(forBus: 0)
        guard AVCaptureDevice.default(for: .audio) != nil, natural.sampleRate > 0, natural.channelCount > 0 else {
            throw DictationError.microphoneUnavailable
        }
        let converter = try DictationAudioConverter(from: natural, to: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
            if let event = converter.convert(buffer) { handler(event) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    /// Stops listening for changes first, so this source's own deactivation never reads as the
    /// microphone going away, then the engine, then hands back a session only this source took.
    private func close() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        #if os(iOS)
        guard isSessionActive else { return }
        isSessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.error("Dictation audio session could not deactivate: \(error.localizedDescription)")
        }
        #endif
    }
}

/// Plays a recording into a session in real time, then stays open like a quiet microphone.
package final class FileDictationSource: DictationAudioSource, @unchecked Sendable {
    private let url: URL
    private let stopsAfter: TimeInterval?
    private var task: Task<Void, Never>?

    /// `stopsAfter` ends playback early, mid-phrase.
    package init(url: URL, stopsAfter: TimeInterval? = nil) {
        self.url = url
        self.stopsAfter = stopsAfter
    }

    package func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let converter = try DictationAudioConverter(from: file.processingFormat, to: format)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        let limit = stopsAfter.map { AVAudioFramePosition($0 * file.processingFormat.sampleRate) } ?? file.length
        let reader = FileReader(file: file)
        task = Task.detached {
            while !Task.isCancelled, let buffer = reader.next(chunk, limit: limit) {
                if let event = converter.convert(buffer) { handler(event) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    package func stop() {
        task?.cancel()
        task = nil
    }

    private final class FileReader: @unchecked Sendable {
        let file: AVAudioFile
        init(file: AVAudioFile) { self.file = file }

        func next(_ frames: AVAudioFrameCount, limit: AVAudioFramePosition) -> AVAudioPCMBuffer? {
            let remaining = min(limit, file.length) - file.framePosition
            guard remaining > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                return nil
            }
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(frames), remaining)))
            } catch {
                return nil
            }
            return buffer.frameLength > 0 ? buffer : nil
        }
    }
}

/// An audio source that never produces audio, for scripted sessions.
package final class SilentDictationSource: DictationAudioSource {
    package init() {}
    package func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {}
    package func stop() {}
}

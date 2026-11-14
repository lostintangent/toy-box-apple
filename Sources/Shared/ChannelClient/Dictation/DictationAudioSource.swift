import AVFoundation
import Foundation
import Speech

package enum DictationAudioEvent: Sendable {
    case audio(AnalyzerInput, level: Double)
    case unavailable
}

/// Feeds analyzer-format audio to a dictation session. Tests and checks feed recorded files through
/// the same real `DictationTranscriber` the microphone uses.
package protocol DictationAudioSource: AnyObject {
    func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws
    func stop()
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

/// Captures the default input device with `AVAudioEngine`. Its methods run on the main thread.
package final class MicrophoneDictationSource: DictationAudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: (any NSObjectProtocol)?
    private var isRunning = false

    package init() {}

    package func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
        try capture(format: format, handler: handler)
        // The engine stops when the input device changes. Follow a switch, and report a device that's gone.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, isRunning else { return }
            do {
                try capture(format: format, handler: handler)
            } catch {
                stop()
                handler(.unavailable)
            }
        }
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

    package func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        if isRunning { engine.stop() }
        isRunning = false
    }
}

/// Plays a recording into a session in real time, then stays open like a quiet microphone.
package final class FileDictationSource: DictationAudioSource, @unchecked Sendable {
    private let url: URL
    private let pace: Double
    private let stopsAfter: TimeInterval?
    private var task: Task<Void, Never>?

    /// `pace` 1 is real time and 0 is as fast as possible. `stopsAfter` ends playback early, mid-phrase.
    package init(url: URL, pace: Double = 1, stopsAfter: TimeInterval? = nil) {
        self.url = url
        self.pace = pace
        self.stopsAfter = stopsAfter
    }

    package func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let converter = try DictationAudioConverter(from: file.processingFormat, to: format)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        let limit = stopsAfter.map { AVAudioFramePosition($0 * file.processingFormat.sampleRate) } ?? file.length
        let pace = pace
        let reader = FileReader(file: file)
        task = Task.detached {
            while !Task.isCancelled, let buffer = reader.next(chunk, limit: limit) {
                if let event = converter.convert(buffer) { handler(event) }
                if pace > 0 { try? await Task.sleep(for: .milliseconds(Int(100 / pace))) }
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

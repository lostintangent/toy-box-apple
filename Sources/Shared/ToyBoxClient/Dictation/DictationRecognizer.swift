import AVFoundation
import Foundation
import Speech

@MainActor package protocol DictationRecognizing: AnyObject {
    /// Starts capture and analysis. `onListening` runs once the audio source is live.
    func start(onListening: @escaping @MainActor () -> Void,
               onResult: @escaping @MainActor (String, Bool) -> Void,
               onLevel: @escaping @MainActor @Sendable (Double) -> Void,
               onInterruption: @escaping @MainActor @Sendable () -> Void,
               onFailure: @escaping @MainActor (any Error) -> Void) async throws
    /// Stops capture and returns after every pending word has been finalized and delivered.
    func finish() async throws
    func cancel()
}

/// Runs the on-device `SpeechAnalyzer` with a `DictationTranscriber` over an audio source.
@MainActor package final class DictationRecognizer: DictationRecognizing {
    private static var resolvedLocale: Locale??
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let contextualStrings: [String]
    private let source: DictationAudioSource
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, any Error>?
    private var isStopped = false

    package static func preferredLocale() async -> Locale? {
        if let resolvedLocale { return resolvedLocale }
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current)
        resolvedLocale = .some(locale)
        return locale
    }

    package static func installAssets(
        for locale: Locale, progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let transcriber = transcriber(for: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        else { return }
        progress(0)
        let observation = request.progress.observe(\.fractionCompleted) { reported, _ in
            let fraction = reported.fractionCompleted
            Task { @MainActor in progress(fraction) }
        }
        defer { observation.invalidate() }
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            request.progress.cancel()
        }
        try Task.checkCancellation()
    }

    /// `progressiveLongDictation` with frequent finalization, so each phrase settles at a pause
    /// rather than the whole session staying tentative until Stop.
    package static func transcriber(for locale: Locale) -> DictationTranscriber {
        let preset = DictationTranscriber.Preset.progressiveLongDictation
        return DictationTranscriber(locale: locale, contentHints: preset.contentHints,
                                    transcriptionOptions: preset.transcriptionOptions,
                                    reportingOptions: preset.reportingOptions.union([.frequentFinalization]),
                                    attributeOptions: preset.attributeOptions)
    }

    package init(locale: Locale, contextualStrings: [String], source: DictationAudioSource) {
        transcriber = Self.transcriber(for: locale)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        self.contextualStrings = contextualStrings
        self.source = source
    }

    package func start(onListening: @escaping @MainActor () -> Void,
               onResult: @escaping @MainActor (String, Bool) -> Void,
               onLevel: @escaping @MainActor @Sendable (Double) -> Void,
               onInterruption: @escaping @MainActor @Sendable () -> Void,
               onFailure: @escaping @MainActor (any Error) -> Void) async throws {
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        guard let format, !isStopped else { throw CancellationError() }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = continuation
        // Capture starts first and buffers into the stream, so words spoken while the model loads aren't lost.
        try source.start(format: format) { event in
            switch event {
            case .audio(let input, let level):
                continuation.yield(input)
                Task { @MainActor in onLevel(level) }
            case .unavailable:
                Task { @MainActor in onInterruption() }
            }
        }
        onListening()
        let transcriber = transcriber
        results = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    onResult(String(result.text.characters), result.isFinal)
                }
            } catch {
                if !(error is CancellationError) { onFailure(error) }
                throw error
            }
        }
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        try await analyzer.setContext(context)
        try await analyzer.start(inputSequence: stream)
    }

    package func finish() async throws {
        isStopped = true
        source.stop()
        continuation?.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results?.value
    }

    package func cancel() {
        isStopped = true
        source.stop()
        continuation?.finish()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Plays scripted transcriber results and a steady input level.
@MainActor package final class ScriptedDictationRecognizer: DictationRecognizing {
    private let results: [(String, Bool)]
    private let level: Double
    /// False stalls the final pass until cancelled, like a transcriber that never answers.
    private let finishes: Bool
    private var task: Task<Void, Never>?
    private var stall: CheckedContinuation<Void, Never>?

    package init(results: [(String, Bool)], level: Double, finishes: Bool = true) {
        self.results = results
        self.level = level
        self.finishes = finishes
    }

    package func start(onListening: @escaping @MainActor () -> Void,
               onResult: @escaping @MainActor (String, Bool) -> Void,
               onLevel: @escaping @MainActor @Sendable (Double) -> Void,
               onInterruption: @escaping @MainActor @Sendable () -> Void,
               onFailure: @escaping @MainActor (any Error) -> Void) async throws {
        onListening()
        let results = results
        let level = level
        task = Task {
            var pending = results[...]
            while !Task.isCancelled {
                onLevel(level)
                if let (text, isFinal) = pending.popFirst() { onResult(text, isFinal) }
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    package func finish() async throws {
        task?.cancel()
        guard !finishes else { return }
        await withCheckedContinuation { stall = $0 }
        throw CancellationError()
    }

    package func cancel() {
        task?.cancel()
        stall?.resume()
        stall = nil
    }
}

import AppKit
import AVFoundation
import Observation
import Speech

/// The words of one dictation session: what the transcriber has finalized, then its current guess.
struct DictationTranscript: Equatable {
    private(set) var finalized = ""
    private(set) var tentative = ""

    var isEmpty: Bool { visible.isEmpty }
    /// Everything the composer shows. `finalized` is always its prefix.
    var visible: String { Self.join(finalized, tentative) }

    /// Returns whether the shown words changed.
    @discardableResult
    mutating func receive(_ text: String, isFinal: Bool) -> Bool {
        let old = self
        if isFinal {
            finalized = Self.join(finalized, text)
            tentative = ""
        } else {
            tentative = text
        }
        return visible != old.visible || finalized != old.finalized
    }

    /// Keeps every word the person has seen, for stops that can't wait for the transcriber.
    mutating func promoteTentative() {
        finalized = visible
        tentative = ""
    }

    mutating func discardTentative() { tentative = "" }

    /// Joins transcriber segments, which carry their own leading spaces, such as "facing", "?" and " and check".
    static func join(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return String(tail.drop(while: \.isWhitespace)) }
        guard let last = head.last, let first = tail.first else { return head }
        if !last.isWhitespace, first.isLetter || first.isNumber { return head + " " + tail }
        return head + tail
    }

    /// The spaces that separate dictated words from the text around the caret.
    static func padding(for words: String, after previous: Character?, before next: Character?) -> (String, String) {
        guard let first = words.first, let last = words.last else { return ("", "") }
        let leading = previous.map { !$0.isWhitespace && (first.isLetter || first.isNumber) } == true ? " " : ""
        let trailing = next.map { $0.isLetter || $0.isNumber } == true && !last.isWhitespace ? " " : ""
        return (leading, trailing)
    }
}

/// The composer text view, which shows dictation at the caret and commits it as one undoable edit.
@MainActor protocol DictationTextTarget: AnyObject {
    var isInKeyWindow: Bool { get }
    /// Focuses the composer and anchors the session at the caret, replacing any selection.
    func beginDictation() -> Bool
    func showDictation(_ transcript: DictationTranscript)
    func endDictation(_ finalized: String)
}

enum DictationAudioEvent: Sendable {
    case audio(AnalyzerInput, level: Double)
    case unavailable
}

/// Feeds analyzer-format audio to a dictation session. Tests and checks feed recorded files through
/// the same real `DictationTranscriber` the microphone uses.
protocol DictationAudioSource: AnyObject {
    func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws
    func stop()
}

enum DictationMicrophoneAccess: Equatable {
    case undetermined, denied, granted
}

/// Which permission keeps the Dictate button from listening.
enum DictationAccess: Equatable {
    case microphone, speechRecognition

    var title: String {
        self == .microphone ? "Microphone Access Is Off" : "Speech Recognition Access Is Off"
    }

    var explanation: String {
        self == .microphone
            ? "Allow Toy Box to use the microphone in Privacy & Security settings. The Dictation key still works."
            : "Allow Toy Box to use speech recognition in Privacy & Security settings. The Dictation key still works."
    }

    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?"
            + (self == .microphone ? "Privacy_Microphone" : "Privacy_SpeechRecognition"))
    }
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

/// The platform services dictation depends on. Tests and snapshot states replace them.
@MainActor struct DictationSystem {
    var supportedLocale: () async -> Locale?
    /// Finding the default input device starts Core Audio, so only the first click asks.
    var hasMicrophone: () async -> Bool
    var microphoneAccess: () -> DictationMicrophoneAccess
    var requestMicrophoneAccess: () async -> Bool
    var speechRecognitionDenied: () -> Bool
    /// Installs the language asset if needed, reporting progress only when a download is required.
    var installAssets: (Locale, @escaping @MainActor @Sendable (Double) -> Void) async throws -> Void
    var makeSource: () -> DictationAudioSource
    var makeRecognizer: (Locale, [String], DictationAudioSource) -> any DictationRecognizing
    var announce: (String) -> Void
    var openSettings: (DictationAccess) -> Void
    var silenceTimeout: Duration = .seconds(30)
    var finalizeTimeout: Duration = .seconds(3)
}

extension DictationSystem {
    private static var resolvedLocale: Locale??

    static var live: DictationSystem {
        var system = DictationSystem(
            supportedLocale: {
                if let resolvedLocale { return resolvedLocale }
                let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current)
                resolvedLocale = .some(locale)
                return locale
            },
            hasMicrophone: { await Task.detached { AVCaptureDevice.default(for: .audio) != nil }.value },
            microphoneAccess: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: .granted
                case .notDetermined: .undetermined
                default: .denied
                }
            },
            requestMicrophoneAccess: { await AVCaptureDevice.requestAccess(for: .audio) },
            speechRecognitionDenied: {
                [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus())
            },
            installAssets: { locale, progress in
                let transcriber = DictationRecognizer.transcriber(for: locale)
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
            },
            makeSource: { MicrophoneDictationSource() },
            makeRecognizer: { DictationRecognizer(locale: $0, contextualStrings: $1, source: $2) },
            announce: { message in
                guard let element = NSApp.keyWindow ?? NSApp.mainWindow else { return }
                NSAccessibility.post(element: element, notification: .announcementRequested,
                                     userInfo: [.announcement: message,
                                                .priority: NSAccessibilityPriorityLevel.high.rawValue])
            },
            openSettings: { access in
                if let url = access.settingsURL { NSWorkspace.shared.open(url) }
            }
        )
#if DEBUG
        if let url = recordingOverride {
            system.hasMicrophone = { true }
            system.microphoneAccess = { .granted }
            system.makeSource = { FileDictationSource(url: url) }
        }
#endif
        return system
    }

#if DEBUG
    /// Lets real-window checks feed a recording through the real transcriber without a microphone.
    static var recordingOverride: URL? {
        ProcessInfo.processInfo.environment["TOYBOX_DICTATION_AUDIO_FILE"].map { URL(fileURLWithPath: $0) }
    }
#endif
}

@MainActor protocol DictationRecognizing: AnyObject {
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

/// Runs macOS 26's on-device `SpeechAnalyzer` with a `DictationTranscriber` over an audio source.
@MainActor final class DictationRecognizer: DictationRecognizing {
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let contextualStrings: [String]
    private let source: DictationAudioSource
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, any Error>?
    private var isStopped = false

    /// `progressiveLongDictation` with frequent finalization, so each phrase settles at a pause
    /// rather than the whole session staying tentative until Stop.
    static func transcriber(for locale: Locale) -> DictationTranscriber {
        let preset = DictationTranscriber.Preset.progressiveLongDictation
        return DictationTranscriber(locale: locale, contentHints: preset.contentHints,
                                    transcriptionOptions: preset.transcriptionOptions,
                                    reportingOptions: preset.reportingOptions.union([.frequentFinalization]),
                                    attributeOptions: preset.attributeOptions)
    }

    init(locale: Locale, contextualStrings: [String], source: DictationAudioSource) {
        transcriber = Self.transcriber(for: locale)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        self.contextualStrings = contextualStrings
        self.source = source
    }

    func start(onListening: @escaping @MainActor () -> Void,
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

    func finish() async throws {
        isStopped = true
        source.stop()
        continuation?.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results?.value
    }

    func cancel() {
        isStopped = true
        source.stop()
        continuation?.finish()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Converts captured or recorded buffers to the analyzer's format and measures their level.
private final class DictationAudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat

    init(from source: AVAudioFormat, to format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw DictationError.unsupportedAudioFormat
        }
        self.converter = converter
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> DictationAudioEvent? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let supplied = SuppliedFlag()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return .audio(AnalyzerInput(buffer: output), level: Self.level(of: buffer))
    }

    /// Maps the buffer's RMS from -50...-10 dBFS onto 0...1.
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let channels = buffer.floatChannelData {
            for index in 0..<frames { sum += channels[0][index] * channels[0][index] }
        } else if let channels = buffer.int16ChannelData {
            for index in 0..<frames {
                let sample = Float(channels[0][index]) / Float(Int16.max)
                sum += sample * sample
            }
        } else {
            return 0
        }
        let rms = (sum / Float(frames)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return Double(min(max((decibels + 50) / 40, 0), 1))
    }

    private final class SuppliedFlag: @unchecked Sendable { var value = false }
}

/// Captures the default input device with `AVAudioEngine`. Its methods run on the main thread.
final class MicrophoneDictationSource: DictationAudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: (any NSObjectProtocol)?
    private var isRunning = false

    func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
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

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        if isRunning { engine.stop() }
        isRunning = false
    }
}

/// Plays a recording into a session in real time, then stays open like a quiet microphone.
final class FileDictationSource: DictationAudioSource, @unchecked Sendable {
    private let url: URL
    private let pace: Double
    private let stopsAfter: TimeInterval?
    private var task: Task<Void, Never>?

    /// `pace` 1 is real time and 0 is as fast as possible. `stopsAfter` ends playback early, mid-phrase.
    init(url: URL, pace: Double = 1, stopsAfter: TimeInterval? = nil) {
        self.url = url
        self.pace = pace
        self.stopsAfter = stopsAfter
    }

    func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
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

    func stop() {
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

/// The Dictate button's state and one dictation session at a time for one composer.
@MainActor @Observable
final class ComposerDictation {
    enum Availability: Equatable {
        case checking, unsupported, noMicrophone, available
    }

    enum Phase: Equatable {
        case idle
        /// Asking for access or loading the model, before any audio is captured.
        case preparing
        case downloading(Double)
        case listening
        /// Waiting for the transcriber to finalize the last words.
        case finishing
    }

    enum Notice: Equatable {
        case downloading(language: String)
        case failed(String)
        /// Send held the message back because dictation didn't finish. It describes the draft at
        /// `revision`, and clears once the draft changes or the person sends.
        case unsent(revision: UUID?)
        /// A click found no microphone. It clears once one is connected.
        case noMicrophone

        var text: String {
            switch self {
            case .downloading(let language): "Downloading \(language) dictation. This happens once."
            case .failed(let message): message
            case .noMicrophone: "Connect a microphone to dictate."
            case .unsent: "Dictation didn't finish, so the message wasn't sent. Check the last words, then send."
            }
        }
    }

    enum StopReason {
        case button, escape, send, silence, windowResigned
    }

    private(set) var availability: Availability = .checking
    private(set) var phase: Phase = .idle
    private(set) var accessOff: DictationAccess?
    private(set) var notice: Notice?
    /// The smoothed input level, updated about 12 times a second while listening.
    private(set) var level: Double = 0
    /// True when dictated words, tentative or final, are showing in the composer.
    private(set) var hasWords = false
    /// True from the moment dictation anchors at the caret until its words are committed.
    private(set) var isSessionActive = false
    var showsAccessExplanation = false

    var isListening: Bool { phase == .listening || phase == .finishing }
    var hasTentativeWords: Bool { !transcript.tentative.isEmpty }

    @ObservationIgnored weak var target: (any DictationTextTarget)?
    @ObservationIgnored var contextualStrings: [String] = []
    /// The composer draft's current revision, read when Send is held back so the commit itself
    /// doesn't count as an edit.
    @ObservationIgnored var draftRevision: () -> UUID? = { nil }
    @ObservationIgnored var system: DictationSystem
    @ObservationIgnored private var locale: Locale?
    @ObservationIgnored private var transcript = DictationTranscript()
    @ObservationIgnored private var recognizer: (any DictationRecognizing)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var finishing: Task<Bool, Never>?
    @ObservationIgnored private var silenceWatch: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastWordsAt = ContinuousClock.now
    @ObservationIgnored private var lastLevelAt = ContinuousClock.now
    @ObservationIgnored private var rawLevel: Double = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var isActive = false
    /// True from the first click on, once devices and access have been checked.
    @ObservationIgnored private(set) var isTracking = false

    init(system: DictationSystem = .live) {
        self.system = system
    }

    /// Checks the language, which decides whether Dictate shows. The microphone and its access
    /// wait for the first click, so launch and channel switches never start Core Audio.
    func activate() {
        guard !isActive else { return }
        isActive = true
        if isTracking { observe() }
        Task { await refresh() }
    }

    /// Commits any session and stops tracking, such as when the composer goes away.
    func deactivate() {
        isActive = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        commitNow()
        if phase != .idle { cancelPreparation() }
    }

    /// Checks devices and access now and follows their changes from here on.
    func startTracking() async {
        guard !isTracking else { return }
        isTracking = true
        if isActive { observe() }
        await refreshDevicesAndAccess()
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refreshDevicesAndAccess() }
                }
            })
        }
    }

    /// Commits any session to the draft it was spoken into and drops what described that draft,
    /// such as when the window switches channels. Device and access tracking carry on.
    func leaveDraft() {
        commitNow()
        if phase != .idle { cancelPreparation() }
        notice = nil
        showsAccessExplanation = false
    }

    func refresh() async {
        if locale == nil { locale = await system.supportedLocale() }
        guard locale != nil else {
            availability = .unsupported
            return
        }
        if isTracking {
            await refreshDevicesAndAccess()
        } else if availability == .checking {
            availability = .available
        }
    }

    private func refreshDevicesAndAccess() async {
        guard availability != .unsupported, locale != nil else { return }
        let hasMicrophone = await system.hasMicrophone()
        availability = hasMicrophone ? .available : .noMicrophone
        if hasMicrophone, notice == .noMicrophone { notice = nil }
        let restored = switch accessOff {
        case .microphone: system.microphoneAccess() != .denied
        case .speechRecognition: !system.speechRecognitionDenied()
        case nil: false
        }
        if restored {
            accessOff = nil
            showsAccessExplanation = false
        } else if accessOff == nil, system.microphoneAccess() == .denied {
            accessOff = .microphone
        }
    }

    /// The Dictate button's action.
    func toggle() {
        switch phase {
        case .idle:
            if accessOff != nil {
                showsAccessExplanation = true
            } else {
                start()
            }
        case .preparing, .downloading:
            cancelPreparation()
        case .listening:
            Task { await stop(.button) }
        case .finishing:
            break
        }
    }

    func openSettings() {
        showsAccessExplanation = false
        if let accessOff { system.openSettings(accessOff) }
    }

    func dismissNotice() { notice = nil }

    /// Clears the unsent notice once the person edits the draft it describes.
    func draftChanged(to revision: UUID) {
        if case .unsent(let described)? = notice, described != revision { notice = nil }
    }

    /// Clears the unsent notice when the person sends.
    func draftSent() {
        if case .unsent? = notice { notice = nil }
    }

    func windowResignedKey() {
        if isListening { Task { await stop(.windowResigned) } }
    }

    private func start() {
        guard availability == .available, let locale else { return }
        notice = nil
        generation += 1
        let generation = generation
        phase = .preparing
        preparation = Task { await prepareAndListen(locale: locale, generation: generation) }
    }

    private func prepareAndListen(locale: Locale, generation: Int) async {
        if !isTracking {
            await startTracking()
            guard self.generation == generation else { return }
            guard availability == .available else {
                phase = .idle
                notice = .noMicrophone
                system.announce(Notice.noMicrophone.text)
                return
            }
        }
        switch system.microphoneAccess() {
        case .denied:
            accessOff = .microphone
            showsAccessExplanation = true
            phase = .idle
            return
        case .undetermined:
            let granted = await system.requestMicrophoneAccess()
            guard self.generation == generation else { return }
            guard granted else {
                accessOff = .microphone
                phase = .idle
                return
            }
        case .granted:
            break
        }
        let language = Locale.current.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "")
            ?? locale.identifier
        do {
            try await system.installAssets(locale) { [weak self] progress in
                guard let self, self.generation == generation else { return }
                notice = .downloading(language: language)
                phase = .downloading(min(max(progress, 0), 1))
            }
        } catch {
            guard self.generation == generation else { return }
            phase = .idle
            notice = error is CancellationError ? nil
                : .failed("\(language) dictation could not be downloaded. \(error.localizedDescription)")
            return
        }
        guard self.generation == generation else { return }
        let downloaded = notice == .downloading(language: language)
        if downloaded { notice = nil }
        // After a download, only start listening if this composer is still where the person is typing.
        guard let target, !downloaded || target.isInKeyWindow, target.beginDictation() else {
            phase = .idle
            return
        }
        phase = .preparing
        isSessionActive = true
        transcript = .init()
        hasWords = false
        let recognizer = system.makeRecognizer(locale, contextualStrings, system.makeSource())
        self.recognizer = recognizer
        do {
            try await recognizer.start(
                onListening: { [weak self] in
                    guard let self, self.generation == generation else { return }
                    phase = .listening
                    lastWordsAt = .now
                    system.announce("Listening")
                    watchSilence(generation: generation)
                },
                onResult: { [weak self] text, isFinal in
                    guard let self, self.generation == generation else { return }
                    receive(text, isFinal: isFinal)
                },
                onLevel: { [weak self] level in
                    guard let self, self.generation == generation else { return }
                    receiveLevel(level)
                },
                onInterruption: { [weak self] in
                    guard let self, self.generation == generation else { return }
                    Task { await self.stop(failure: "Dictation stopped because the microphone became unavailable.") }
                },
                onFailure: { [weak self] error in
                    guard let self, self.generation == generation else { return }
                    fail("Dictation stopped. \(error.localizedDescription)")
                }
            )
        } catch {
            guard self.generation == generation else { return }
            if system.speechRecognitionDenied() {
                fail(nil)
                accessOff = .speechRecognition
                showsAccessExplanation = true
            } else if !(error is CancellationError) {
                fail("Dictation could not start. \(error.localizedDescription)")
            }
        }
    }

    private func receive(_ text: String, isFinal: Bool) {
        guard isSessionActive, transcript.receive(text, isFinal: isFinal) else { return }
        lastWordsAt = .now
        hasWords = !transcript.isEmpty
        target?.showDictation(transcript)
    }

    private func receiveLevel(_ value: Double) {
        rawLevel = max(value, rawLevel * 0.85)
        let now = ContinuousClock.now
        guard phase == .listening, now - lastLevelAt >= .milliseconds(80) else { return }
        lastLevelAt = now
        let smoothing = rawLevel > level ? 0.6 : 0.3
        level += (rawLevel - level) * smoothing
        rawLevel = 0
    }

    private func watchSilence(generation: Int) {
        silenceWatch?.cancel()
        silenceWatch = Task { [weak self] in
            while true {
                guard let self, self.generation == generation, phase == .listening else { return }
                let deadline = lastWordsAt + system.silenceTimeout
                if ContinuousClock.now >= deadline {
                    await stop(.silence)
                    return
                }
                do { try await Task.sleep(until: deadline) } catch { return }
            }
        }
    }

    /// Stops listening and waits for the transcriber to finalize every pending word. Returns false
    /// when words the person saw could not be confirmed, which keeps them in the draft unsent.
    @discardableResult
    func stop(_ reason: StopReason = .button) async -> Bool {
        switch phase {
        case .preparing where !isSessionActive, .downloading:
            if reason != .send { cancelPreparation() }
            return true
        case .idle:
            return true
        case .finishing:
            return await finishing?.value ?? true
        case .preparing, .listening:
            break
        }
        return await finish(failure: nil, reason: reason)
    }

    private func stop(failure: String) async {
        guard isSessionActive else { return }
        _ = await finish(failure: failure, reason: nil)
        await refreshDevicesAndAccess()
    }

    private func finish(failure: String?, reason: StopReason?) async -> Bool {
        let generation = generation
        phase = .finishing
        silenceWatch?.cancel()
        let recognizer = recognizer
        let timeout = system.finalizeTimeout
        let task = Task { [weak self] () -> Bool in
            let finalized = await Self.finalize(recognizer, within: timeout)
            guard let self, self.generation == generation else { return finalized }
            if !finalized { recognizer?.cancel() }
            let unconfirmed = !finalized && !transcript.tentative.isEmpty
            transcript.promoteTentative()
            endSession()
            if let failure {
                notice = .failed(failure)
            } else if unconfirmed, reason == .send {
                notice = .unsent(revision: draftRevision())
            }
            return !unconfirmed
        }
        finishing = task
        return await task.value
    }

    /// Returns true when the transcriber delivered its final words in time, without waiting on a
    /// transcriber that never answers.
    private static func finalize(_ recognizer: (any DictationRecognizing)?, within timeout: Duration) async -> Bool {
        guard let recognizer else { return true }
        let outcome = FinalizeOutcome()
        return await withCheckedContinuation { continuation in
            outcome.continuation = continuation
            Task {
                do {
                    try await recognizer.finish()
                    outcome.resolve(true)
                } catch {
                    outcome.resolve(false)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                outcome.resolve(false)
            }
        }
    }

    @MainActor private final class FinalizeOutcome {
        var continuation: CheckedContinuation<Bool, Never>?

        func resolve(_ finalized: Bool) {
            continuation?.resume(returning: finalized)
            continuation = nil
        }
    }

    /// Ends the session at once, keeping every shown word, such as when the person starts typing.
    func commitNow() {
        guard isSessionActive else { return }
        recognizer?.cancel()
        transcript.promoteTentative()
        endSession()
    }

    private func fail(_ message: String?) {
        guard isSessionActive || phase != .idle else { return }
        recognizer?.cancel()
        transcript.discardTentative()
        if isSessionActive {
            endSession()
        } else {
            phase = .idle
        }
        if let message { notice = .failed(message) }
    }

    private func endSession() {
        let wasListening = phase == .listening || phase == .finishing
        generation += 1
        silenceWatch?.cancel()
        recognizer = nil
        finishing = nil
        if isSessionActive {
            isSessionActive = false
            target?.endDictation(transcript.finalized)
        }
        transcript = .init()
        hasWords = false
        level = 0
        phase = .idle
        if wasListening { system.announce("Dictation stopped") }
    }

    private func cancelPreparation() {
        preparation?.cancel()
        preparation = nil
        if isSessionActive {
            commitNow()
            return
        }
        generation += 1
        if case .downloading = phase { notice = nil }
        phase = .idle
    }
}

extension DictationSystem {
    /// Deterministic services for snapshot states and tests, with scripted words instead of audio.
    static func scripted(microphone: DictationMicrophoneAccess = .granted, hasMicrophone: Bool = true,
                         downloadProgress: Double? = nil, results: [(String, Bool)] = [],
                         level: Double = 0.75, finishes: Bool = true) -> DictationSystem {
        DictationSystem(
            supportedLocale: { Locale(identifier: "en_US") },
            hasMicrophone: { hasMicrophone },
            microphoneAccess: { microphone },
            requestMicrophoneAccess: { false },
            speechRecognitionDenied: { false },
            installAssets: { _, progress in
                guard let downloadProgress else { return }
                progress(downloadProgress)
                try await Task.sleep(for: .seconds(3_600))
            },
            makeSource: { SilentDictationSource() },
            makeRecognizer: { _, _, _ in
                ScriptedDictationRecognizer(results: results, level: level, finishes: finishes)
            },
            announce: { _ in },
            openSettings: { _ in }
        )
    }
}

/// An audio source that never produces audio, for scripted sessions.
final class SilentDictationSource: DictationAudioSource {
    func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {}
    func stop() {}
}

/// Plays scripted transcriber results and a steady input level.
@MainActor final class ScriptedDictationRecognizer: DictationRecognizing {
    private let results: [(String, Bool)]
    private let level: Double
    /// False stalls the final pass until cancelled, like a transcriber that never answers.
    private let finishes: Bool
    private var task: Task<Void, Never>?
    private var stall: CheckedContinuation<Void, Never>?

    init(results: [(String, Bool)], level: Double, finishes: Bool = true) {
        self.results = results
        self.level = level
        self.finishes = finishes
    }

    func start(onListening: @escaping @MainActor () -> Void,
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

    func finish() async throws {
        task?.cancel()
        guard !finishes else { return }
        await withCheckedContinuation { stall = $0 }
        throw CancellationError()
    }

    func cancel() {
        task?.cancel()
        stall?.resume()
        stall = nil
    }
}

import Foundation
import Observation

/// The Dictate button's state and one dictation session at a time for one composer.
@MainActor @Observable
package final class Dictation {
    package enum Availability: Equatable {
        case checking, unsupported, noMicrophone, available
    }

    package enum Phase: Equatable {
        case idle
        /// Asking for access or loading the model, before any audio is captured.
        case preparing
        case downloading(Double)
        case listening
        /// Waiting for the transcriber to finalize the last words.
        case finishing
    }

    package enum Notice: Equatable {
        case downloading(language: String)
        case failed(String)
        /// Send held the message back because dictation didn't finish. It describes the draft at
        /// `revision`, and clears once the draft changes or the person sends.
        case unsent(revision: UUID?)
        /// A click found no microphone. It clears once one is connected.
        case noMicrophone

        package var text: String {
            switch self {
            case .downloading(let language): "Downloading \(language) dictation. This happens once."
            case .failed(let message): message
            case .noMicrophone: "Connect a microphone to dictate."
            case .unsent: "Dictation didn't finish, so the message wasn't sent. Check the last words, then send."
            }
        }
    }

    package enum StopReason {
        case button, escape, send, silence, windowResigned
    }

    package private(set) var availability: Availability = .checking
    package private(set) var phase: Phase = .idle
    package private(set) var accessOff: DictationAccess?
    package private(set) var notice: Notice?
    /// The smoothed input level, updated about 12 times a second while listening.
    package private(set) var level: Double = 0
    /// True when dictated words, tentative or final, are showing in the composer.
    package private(set) var hasWords = false
    /// True from the moment dictation anchors at the caret until its words are committed.
    package private(set) var isSessionActive = false
    /// True while a send waits for dictation's last words.
    package private(set) var holdsSend = false
    package var showsAccessExplanation = false

    package var isListening: Bool { phase == .listening || phase == .finishing }
    package var hasTentativeWords: Bool { !transcript.tentative.isEmpty }

    @ObservationIgnored package weak var target: (any DictationTextTarget)?
    @ObservationIgnored package var contextualStrings: [String] = []
    /// The composer draft's current revision, read when Send is held back so the commit itself
    /// doesn't count as an edit.
    @ObservationIgnored package var draftRevision: () -> UUID? = { nil }
    @ObservationIgnored package var system: DictationSystem
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
    @ObservationIgnored private var inputRefreshGeneration = 0
    /// True from the first click on, once devices and access have been checked.
    @ObservationIgnored package private(set) var isTracking = false

    package init(system: DictationSystem) {
        self.system = system
    }

    /// Checks the language, which decides whether Dictate shows. The microphone and its access
    /// wait for the first click, so launch and channel switches never start Core Audio.
    package func activate() {
        guard !isActive else { return }
        isActive = true
        if isTracking { observe() }
        Task { await refresh() }
    }

    /// Commits any session and stops tracking, such as when the composer goes away.
    package func deactivate() {
        isActive = false
        inputRefreshGeneration += 1
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        commitNow()
        if phase != .idle { cancelPreparation() }
    }

    /// Checks devices and access now and follows their changes from here on.
    package func startTracking() async {
        guard !isTracking else { return }
        isTracking = true
        if isActive { observe() }
        await refreshDevicesAndAccess()
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in system.refreshNotifications {
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
    package func leaveDraft() {
        commitNow()
        if phase != .idle { cancelPreparation() }
        notice = nil
        showsAccessExplanation = false
    }

    package func refresh() async {
        await refreshSupportedLanguage()
        if locale != nil, isTracking { await refreshDevicesAndAccess() }
    }

    /// A returning composer has no current input-device observation until the next deliberate tap.
    package func refreshLanguageSupport() async {
        inputRefreshGeneration += 1
        if availability == .noMicrophone { availability = .checking }
        await refreshSupportedLanguage()
    }

    private func refreshSupportedLanguage() async {
        if locale == nil { locale = await system.supportedLocale() }
        guard locale != nil else {
            availability = .unsupported
            return
        }
        if availability == .checking { availability = .available }
    }

    @discardableResult
    private func refreshDevicesAndAccess() async -> Bool {
        guard availability != .unsupported, locale != nil else { return false }
        inputRefreshGeneration += 1
        let refreshGeneration = inputRefreshGeneration
        let hasMicrophone = await system.hasMicrophone()
        guard inputRefreshGeneration == refreshGeneration else { return false }
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
        return true
    }

    /// The Dictate button's action.
    package func toggle() {
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

    /// Rechecks input on every deliberate request, including a retained composer's previous failure.
    package func toggleRecheckingInput() {
        guard phase == .idle else {
            toggle()
            return
        }
        generation += 1
        let generation = generation
        notice = nil
        phase = .preparing
        isActive = true
        if isTracking { observe() }
        preparation = Task {
            await refreshSupportedLanguage()
            guard self.generation == generation else { return }
            guard let locale else {
                phase = .idle
                return
            }
            if !isTracking {
                isTracking = true
                observe()
            }
            let checkedCurrentInput = await refreshDevicesAndAccess()
            guard self.generation == generation else { return }
            guard checkedCurrentInput else {
                phase = .idle
                notice = .failed("The microphone changed. Tap Dictate to try again.")
                return
            }
            guard availability == .available else {
                phase = .idle
                notice = .noMicrophone
                system.announce(Notice.noMicrophone.text)
                return
            }
            if accessOff != nil {
                phase = .idle
                showsAccessExplanation = true
                return
            }
            await prepareAndListen(locale: locale, generation: generation)
        }
    }

    package func openSettings() {
        showsAccessExplanation = false
        if let accessOff { system.openSettings(accessOff) }
    }

    package func dismissNotice() { notice = nil }

    /// Clears the unsent notice once the person edits the draft it describes.
    package func draftChanged(to revision: UUID) {
        if case .unsent(let described)? = notice, described != revision { notice = nil }
    }

    package func windowResignedKey() {
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
    /// when words the person saw could not be confirmed, which keeps them in the draft unsent. A
    /// send holds Send while it waits, and clears the unsent notice once it can go ahead.
    @discardableResult
    package func stop(_ reason: StopReason = .button) async -> Bool {
        if reason == .send { holdsSend = true }
        defer { if reason == .send { holdsSend = false } }
        let finalized: Bool
        switch phase {
        case .preparing where !isSessionActive, .downloading:
            if reason != .send { cancelPreparation() }
            finalized = true
        case .idle: finalized = true
        case .finishing: finalized = await finishing?.value ?? true
        case .preparing, .listening: finalized = await finish(failure: nil, reason: reason)
        }
        if finalized, reason == .send, case .unsent? = notice { notice = nil }
        return finalized
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
    package func commitNow() {
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

/// The composer text view, which shows dictation at the caret and commits it as one undoable edit.
@MainActor package protocol DictationTextTarget: AnyObject {
    var isInKeyWindow: Bool { get }
    /// Focuses the composer and anchors the session at the caret, replacing any selection.
    func beginDictation() -> Bool
    func showDictation(_ transcript: DictationTranscript)
    func endDictation(_ finalized: String)
}

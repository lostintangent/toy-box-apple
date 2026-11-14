import AVFoundation
import Foundation
import Observation
import Testing
@testable import ToyBoxClient

/// Dictation's rules both composers share, with scripted recognizers instead of audio. See Dictation
/// in docs/spec.md.
@Suite(.timeLimit(.minutes(1))) @MainActor
struct DictationTests {
    @Test func dictationTranscriptJoinsTranscriberSegments() {
        var transcript = DictationTranscript()
        let changed = transcript.receive(" Can you tighten the sidebar", isFinal: false)
        #expect(changed)
        #expect(transcript.visible == "Can you tighten the sidebar")
        #expect(transcript.finalized.isEmpty)
        transcript.receive("Can you tighten the sidebar spacing", isFinal: true)
        transcript.receive("?", isFinal: true)
        transcript.receive(" and check the", isFinal: false)
        #expect(transcript.finalized == "Can you tighten the sidebar spacing?")
        #expect(transcript.visible == "Can you tighten the sidebar spacing? and check the")
        let repeated = transcript.receive(" and check the", isFinal: false)
        #expect(!repeated)
        transcript.promoteTentative()
        #expect(transcript.finalized == "Can you tighten the sidebar spacing? and check the")
        #expect(transcript.tentative.isEmpty)
        #expect(DictationTranscript.join("Hello", "world") == "Hello world")
        #expect(DictationTranscript.join("Hello", ",") == "Hello,")
        #expect(DictationTranscript.join("Hello\n", "world") == "Hello\nworld")
    }

    @Test func sendingWaitsForFinalWordsAndKeepsUnconfirmedWordsUnsent() async throws {
        var revision = UUID()
        let recognizer = ManualDictationRecognizer()
        var system = DictationSystem.manual(recognizer)
        system.finalizeTimeout = .milliseconds(150)
        let dictation = Dictation(system: system)
        let target = RecordingDictationTarget()
        dictation.target = target
        dictation.draftRevision = { revision }
        await dictation.refresh()
        defer { dictation.deactivate() }

        dictation.toggle()
        try await eventually { dictation.phase == .listening }
        recognizer.send("Check the hed", isFinal: false)
        recognizer.finalWords = [("Check the header.", true)]
        #expect(await dictation.stop(.send))
        #expect(target.commits == ["Check the header."])
        #expect(dictation.notice == nil)

        dictation.toggle()
        try await eventually { dictation.phase == .listening }
        recognizer.send("And the footer", isFinal: false)
        recognizer.hangs = true
        #expect(await !dictation.stop(.send), "A stalled transcriber cannot confirm words for sending")
        #expect(target.commits == ["Check the header.", "And the footer"], "Unconfirmed words reach the text target")
        #expect(dictation.notice == .unsent(revision: revision))
        #expect(!dictation.isSessionActive)

        dictation.draftChanged(to: revision)
        #expect(dictation.notice != nil, "Committing the unconfirmed words is not an edit")
        revision = UUID()
        dictation.draftChanged(to: revision)
        #expect(dictation.notice == nil, "Editing the draft clears the notice")

        dictation.toggle()
        try await eventually { dictation.phase == .listening }
        recognizer.send("Thanks", isFinal: false)
        recognizer.hangs = true
        #expect(await !dictation.stop(.send))
        #expect(dictation.notice == .unsent(revision: revision))
        #expect(await dictation.stop(.send))
        #expect(dictation.notice == nil, "Sending clears the notice")
    }

    @Test func sendingBeforeListeningStopsAStartingMicAndLetsADownloadFinishAtReady() async throws {
        let installing = AsyncStream<Void>.makeStream()
        var system = DictationSystem.manual(ManualDictationRecognizer())
        system.installAssets = { _, _ in
            installing.continuation.yield()
            try await Task.sleep(for: .seconds(3_600))
        }
        let starting = Dictation(system: system)
        starting.target = RecordingDictationTarget()
        await starting.refresh()
        starting.toggle()
        var installs = installing.stream.makeAsyncIterator()
        await installs.next()
        #expect(await starting.stop(.send))
        #expect(starting.phase == .idle, "Send stops a mic that's still starting")

        let finishing = AsyncStream<Void>.makeStream()
        system.installAssets = { _, progress in
            progress(0.5)
            for await _ in finishing.stream { break }
        }
        let target = RecordingDictationTarget()
        target.isInKeyWindow = true
        let downloading = Dictation(system: system)
        downloading.target = target
        await downloading.refresh()
        downloading.toggle()
        try await eventually { downloading.phase == .downloading(0.5) }
        #expect(await downloading.stop(.send))
        #expect(downloading.phase == .downloading(0.5), "Send lets a first-use download keep going")
        finishing.continuation.yield()
        try await eventually { downloading.notice == nil }
        #expect(downloading.phase == .idle, "The finished download returns to Ready")
        #expect(target.begins == 0, "Listening never begins in the next draft")
    }

    @Test func silenceStopsDictationAndKeepsItsWords() async throws {
        let recognizer = ManualDictationRecognizer()
        var system = DictationSystem.manual(recognizer)
        system.silenceTimeout = .milliseconds(250)
        var announcements: [String] = []
        system.announce = { announcements.append($0) }
        let dictation = Dictation(system: system)
        let target = RecordingDictationTarget()
        dictation.target = target
        await dictation.refresh()
        defer { dictation.deactivate() }
        // The words arrive as listening starts, so a busy main actor can't let silence win first.
        recognizer.firstWords = [("Quiet now", true)]
        dictation.toggle()
        try await eventually { target.commits == ["Quiet now"] && !dictation.isSessionActive }
        #expect(dictation.phase == .idle)
        #expect(announcements == ["Listening", "Dictation stopped"])
    }

    @Test func microphoneAccessStatesExplainThemselvesAndRecover() async throws {
        let access = MicrophoneAccessBox()
        var system = DictationSystem.scripted()
        system.microphoneAccess = { access.value }
        system.requestMicrophoneAccess = {
            access.requests += 1
            access.value = access.grants ? .granted : .denied
            return access.grants
        }
        var opened: [DictationAccess] = []
        system.openSettings = { opened.append($0) }
        let dictation = Dictation(system: system)
        await dictation.refresh()
        #expect(dictation.availability == .available)
        #expect(dictation.accessOff == nil, "Access waits for the first click")
        dictation.toggle()
        try await eventually { dictation.showsAccessExplanation }
        #expect(dictation.accessOff == .microphone)
        #expect(dictation.phase == .idle)
        dictation.showsAccessExplanation = false
        dictation.toggle()
        #expect(dictation.showsAccessExplanation, "Later clicks explain at once")
        dictation.openSettings()
        #expect(opened == [.microphone])
        #expect(!dictation.showsAccessExplanation)

        access.value = .granted
        await dictation.refresh()
        #expect(dictation.accessOff == nil)

        access.value = .undetermined
        dictation.toggle()
        try await eventually { dictation.accessOff == .microphone }
        #expect(access.requests == 1)
        #expect(dictation.phase == .idle)

        dictation.system.hasMicrophone = { false }
        await dictation.refresh()
        #expect(dictation.availability == .noMicrophone)

        var unsupported = DictationSystem.scripted()
        unsupported.supportedLocale = { nil }
        let elsewhere = Dictation(system: unsupported)
        await elsewhere.refresh()
        #expect(elsewhere.availability == .unsupported)
    }

    @Test func theMicrophoneAndItsAccessWaitForTheFirstClick() async throws {
        let probe = MicrophoneProbe()
        var system = DictationSystem.scripted()
        system.hasMicrophone = {
            probe.deviceChecks += 1
            return probe.isConnected
        }
        system.microphoneAccess = {
            probe.accessChecks += 1
            return .granted
        }
        var announcements: [String] = []
        system.announce = { announcements.append($0) }
        let dictation = Dictation(system: system)
        dictation.activate()
        defer { dictation.deactivate() }
        try await eventually { dictation.availability != .checking }
        await dictation.refresh()
        #expect(probe.deviceChecks == 0, "Finding the input device starts Core Audio, so activating never does")
        #expect(probe.accessChecks == 0)
        #expect(dictation.availability == .available, "Dictate shows before anything looks for a microphone")

        dictation.toggle()
        try await eventually { dictation.notice == .noMicrophone }
        #expect(dictation.availability == .noMicrophone)
        #expect(dictation.phase == .idle)
        #expect(dictation.notice?.text == "Connect a microphone to dictate.")
        #expect(announcements == ["Connect a microphone to dictate."])
        #expect(probe.deviceChecks == 1)

        probe.isConnected = true
        NotificationCenter.default.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        try await eventually { dictation.availability == .available }
        #expect(dictation.notice == nil)
    }

    @Test func retainedPhoneAppearanceChecksOnlyLanguageSupport() async throws {
        let recognizer = ManualDictationRecognizer()
        let probe = MicrophoneProbe()
        probe.isConnected = true
        var assets = 0
        var system = DictationSystem.manual(recognizer)
        system.refreshNotifications = []
        system.hasMicrophone = { probe.deviceChecks += 1; return probe.isConnected }
        system.microphoneAccess = { probe.accessChecks += 1; return .granted }
        system.installAssets = { _, _ in assets += 1 }
        let dictation = Dictation(system: system)
        let target = RecordingDictationTarget()
        dictation.target = target
        defer { dictation.deactivate() }

        await dictation.refreshLanguageSupport()
        #expect(probe.deviceChecks == 0 && probe.accessChecks == 0 && assets == 0)
        dictation.toggleRecheckingInput()
        try await eventually { dictation.phase == .listening }
        dictation.deactivate()
        let devices = probe.deviceChecks
        let access = probe.accessChecks
        let installed = assets
        await dictation.refreshLanguageSupport()
        #expect(probe.deviceChecks == devices)
        #expect(probe.accessChecks == access)
        #expect(assets == installed)
        #expect(dictation.phase == .idle)
    }

    @Test func everyPhoneDictationTapRechecksInputIncludingAPreviouslyMissingMicrophone() async throws {
        let recognizer = ManualDictationRecognizer()
        let probe = MicrophoneProbe()
        var system = DictationSystem.manual(recognizer)
        system.refreshNotifications = []
        system.hasMicrophone = { probe.deviceChecks += 1; return probe.isConnected }
        system.microphoneAccess = { probe.accessChecks += 1; return .granted }
        let dictation = Dictation(system: system)
        let target = RecordingDictationTarget()
        dictation.target = target
        defer { dictation.deactivate() }

        await dictation.refreshLanguageSupport()
        dictation.toggleRecheckingInput()
        try await eventually { dictation.notice == .noMicrophone }
        #expect(probe.deviceChecks == 1)
        #expect(dictation.availability == .noMicrophone)
        dictation.deactivate()
        await dictation.refreshLanguageSupport()
        #expect(probe.deviceChecks == 1)
        #expect(dictation.availability == .available, "The detached result cannot permanently disable a fresh tap")

        probe.isConnected = true
        dictation.toggleRecheckingInput()
        try await eventually { dictation.phase == .listening }
        #expect(probe.deviceChecks == 2)
        let access = probe.accessChecks
        dictation.commitNow()
        dictation.toggleRecheckingInput()
        try await eventually { dictation.phase == .listening }
        #expect(probe.deviceChecks == 3)
        #expect(probe.accessChecks > access)

        dictation.commitNow()
        dictation.system.microphoneAccess = { .denied }
        dictation.toggleRecheckingInput()
        try await eventually { dictation.showsAccessExplanation }
        #expect(probe.deviceChecks == 4)
        #expect(dictation.accessOff == .microphone)
        #expect(target.begins == 2)
    }

    @Test func anObsoleteHeldInputCheckCannotOverwriteANewerPhoneTap() async throws {
        let recognizer = ManualDictationRecognizer()
        var checks = 0
        var accessChecks = 0
        var holdsNextCheck = false
        var held: CheckedContinuation<Bool, Never>?
        let holding = AsyncStream<Void>.makeStream()
        var system = DictationSystem.manual(recognizer)
        system.refreshNotifications = []
        system.hasMicrophone = {
            checks += 1
            if holdsNextCheck {
                holdsNextCheck = false
                return await withCheckedContinuation {
                    held = $0
                    holding.continuation.yield()
                }
            }
            return true
        }
        system.microphoneAccess = { accessChecks += 1; return .granted }
        let dictation = Dictation(system: system)
        let target = RecordingDictationTarget()
        dictation.target = target
        defer {
            held?.resume(returning: false)
            dictation.deactivate()
        }

        await dictation.refresh()
        await dictation.startTracking()
        holdsNextCheck = true
        let obsolete = Task { await dictation.refresh() }
        var holds = holding.stream.makeAsyncIterator()
        await holds.next()
        dictation.deactivate()
        await dictation.refreshLanguageSupport()
        dictation.toggleRecheckingInput()
        try await eventually { dictation.phase == .listening }
        #expect(checks == 3)
        let freshAccessChecks = accessChecks
        held?.resume(returning: false)
        held = nil
        await obsolete.value
        #expect(dictation.availability == .available)
        #expect(dictation.phase == .listening)
        #expect(dictation.notice == nil)
        #expect(accessChecks == freshAccessChecks, "An obsolete device result never reads or changes current access")
    }

    @Test func firstUseDownloadShowsProgressCancelsAndOnlyStartsInTheKeyWindow() async throws {
        let dictation = Dictation(system: .scripted(downloadProgress: 0.35))
        await dictation.refresh()
        dictation.toggle()
        try await eventually { dictation.phase == .downloading(0.35) }
        #expect(dictation.notice?.text == "Downloading English dictation. This happens once.")
        dictation.toggle()
        #expect(dictation.phase == .idle)
        #expect(dictation.notice == nil)

        let recognizer = ManualDictationRecognizer()
        var system = DictationSystem.manual(recognizer)
        system.installAssets = { _, progress in
            progress(0.5)
            progress(1)
        }
        let target = RecordingDictationTarget()
        let downloaded = Dictation(system: system)
        downloaded.target = target
        await downloaded.refresh()
        downloaded.toggle()
        try await eventually { downloaded.phase == .idle && downloaded.notice == nil }
        #expect(target.begins == 0, "A finished download doesn't start listening in a background window")

        target.isInKeyWindow = true
        downloaded.toggle()
        try await eventually { downloaded.phase == .listening }
        #expect(target.begins == 1)
        downloaded.commitNow()
    }
}

extension DictationSystem {
    static func manual(_ recognizer: ManualDictationRecognizer) -> DictationSystem {
        var system = DictationSystem.scripted()
        system.makeRecognizer = { _, _, _ in recognizer }
        return system
    }
}

/// Delivers the words the test speaks, and finalizes or stalls on demand.
@MainActor final class ManualDictationRecognizer: DictationRecognizing {
    /// Heard the moment listening starts, before any timer can run.
    var firstWords: [(String, Bool)] = []
    /// The final pass that stopping waits for.
    var finalWords: [(String, Bool)] = []
    var hangs = false
    private(set) var isCancelled = false
    private var onResult: (@MainActor (String, Bool) -> Void)?
    private var finishing: CheckedContinuation<Void, any Error>?

    func start(onListening: @escaping @MainActor () -> Void,
               onResult: @escaping @MainActor (String, Bool) -> Void,
               onLevel: @escaping @MainActor @Sendable (Double) -> Void,
               onInterruption: @escaping @MainActor @Sendable () -> Void,
               onFailure: @escaping @MainActor (any Error) -> Void) async throws {
        isCancelled = false
        hangs = false
        finalWords = []
        self.onResult = onResult
        onListening()
        for (text, isFinal) in firstWords { onResult(text, isFinal) }
    }

    func send(_ text: String, isFinal: Bool) { onResult?(text, isFinal) }

    func finish() async throws {
        if hangs, !isCancelled {
            try await withCheckedThrowingContinuation { finishing = $0 }
        }
        if isCancelled { throw CancellationError() }
        for (text, isFinal) in finalWords { onResult?(text, isFinal) }
    }

    func cancel() {
        isCancelled = true
        finishing?.resume(throwing: CancellationError())
        finishing = nil
    }
}

@MainActor @Observable private final class RecordingDictationTarget: DictationTextTarget {
    var isInKeyWindow = false
    private(set) var begins = 0
    private(set) var commits: [String] = []

    func beginDictation() -> Bool {
        begins += 1
        return true
    }

    func showDictation(_ transcript: DictationTranscript) {}
    func endDictation(_ finalized: String) { commits.append(finalized) }
}

@MainActor private final class MicrophoneProbe {
    var isConnected = false
    var deviceChecks = 0
    var accessChecks = 0
}

@MainActor private final class MicrophoneAccessBox {
    var value = DictationMicrophoneAccess.denied
    var grants = false
    var requests = 0
}

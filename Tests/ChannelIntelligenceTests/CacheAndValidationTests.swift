import Foundation
import FoundationModels
import Testing
@testable import ChannelIntelligence

struct IntelligenceCacheTests {
    func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "ChannelIntelligenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func lruEvictsTheLeastRecentlyUsed() {
        var cache = LRUCache<String, Int>(limit: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        #expect(cache.value(for: "a") == 1)
        cache.set(3, for: "c")
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.count == 2)
    }

    @Test func descriptionsPersistAcrossLaunches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await AltTextStore(directory: directory).store(.init(text: "A beach at sunset."), for: "server\nabc")
        await AltTextStore(directory: directory).store(.init(text: nil), for: "server\nempty")

        let relaunched = AltTextStore(directory: directory)
        #expect(await relaunched.entry(for: "server\nabc") == .init(text: "A beach at sunset."))
        #expect(await relaunched.entry(for: "server\nempty") == .init(text: nil))
        #expect(await relaunched.entry(for: "other\nabc") == nil)
    }

    @Test func diskCacheStaysUnderItsCap() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AltTextStore(directory: directory, byteLimit: 2_000, memoryLimit: 1)
        let text = String(repeating: "x", count: 180)
        for index in 0..<40 {
            await store.store(.init(text: text), for: "key-\(index)")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(bytes <= 2_000)
        #expect(files.count < 40)
        #expect(await store.entry(for: "key-39") != nil)
    }
}

struct AvailabilityTests {
    @Test func modelStatesMapToReasons() {
        #expect(IntelligenceAvailability(.available, supportsLocale: true) == .available)
        #expect(IntelligenceAvailability(.available, supportsLocale: false) == .unavailable(.unsupportedLanguage))
        #expect(IntelligenceAvailability(.unavailable(.deviceNotEligible), supportsLocale: true) == .unavailable(.deviceNotEligible))
        #expect(IntelligenceAvailability(.unavailable(.appleIntelligenceNotEnabled), supportsLocale: true)
                == .unavailable(.appleIntelligenceNotEnabled))
        #expect(IntelligenceAvailability(.unavailable(.modelNotReady), supportsLocale: true) == .unavailable(.modelNotReady))
    }

    @Test func failuresDecideCaching() {
        struct Unexpected: Error {}
        #expect(GenerationFailure(CancellationError()) == .cancelled)
        #expect(GenerationFailure(Unexpected()) == .transient)
    }

    @Test func unavailableServiceSkipsTheModel() async throws {
        struct Unavailable: ChannelIntelligenceService {
            var availability: IntelligenceAvailability { .unavailable(.appleIntelligenceNotEnabled) }
            func catchUp(_ request: CatchUpRequest) async -> CatchUpResult { .unavailable(.appleIntelligenceNotEnabled) }
            func altText(_ request: AltTextRequest) async -> AltText? { nil }
        }
        let service: any ChannelIntelligenceService = Unavailable()
        #expect(!service.availability.isAvailable)
    }
}

struct AltTextValidationTests {
    @Test func unclearImagesGetNoDescription() {
        #expect(AltTextPrompt.validated(kind: "unclear", description: "A blank square.", recognizedText: "") == nil)
        #expect(AltTextPrompt.validated(kind: "photo", description: "UNCLEAR", recognizedText: "") == nil)
        #expect(AltTextPrompt.validated(kind: "photo", description: "  ", recognizedText: "") == nil)
    }

    @Test func boilerplateOpeningsAreRemoved() {
        #expect(AltTextPrompt.validated(kind: "photo", description: "Image of a beach at sunset", recognizedText: "")
                == AltText(text: "A beach at sunset."))
        #expect(AltTextPrompt.validated(kind: "photo", description: "This image shows a tree in a field.", recognizedText: "")
                == AltText(text: "A tree in a field."))
    }

    @Test func textAndNamesMustMatchRecognition() {
        let recognized = "Lead\nMessages now use one state\nGeneral\nShow in menu bar"
        #expect(AltTextPrompt.validated(kind: "screenshot",
                                        description: "A chat interface with a message from 'Tim' and a reply from 'Assistant'.",
                                        recognizedText: recognized) == nil)
        #expect(AltTextPrompt.validated(kind: "screenshot",
                                        description: "A chat window where Tim replies to a message.",
                                        recognizedText: recognized) == nil)
        #expect(AltTextPrompt.validated(kind: "screenshot",
                                        description: "A settings window with a \u{201C}Show in menu bar\u{201D} option under General.",
                                        recognizedText: recognized)
                == AltText(text: "A settings window with a \u{201C}Show in menu bar\u{201D} option under General."))
        #expect(AltTextPrompt.validated(kind: "chart", description: "A chart showing 42% growth.", recognizedText: "growth 24%") == nil)
    }

    @Test func activitiesAreNotGuessed() {
        // Live model output for a screenshot of Overview, which shows no meeting.
        #expect(AltTextPrompt.validated(kind: "screenshot",
                                        description: "Screen showing a workspace with tasks and team members in a meeting.",
                                        recognizedText: "Overview Tasks Ada Moss Review the handoff") == nil)
        #expect(AltTextPrompt.validated(kind: "screenshot", description: "A calendar with a meeting at noon.",
                                        recognizedText: "Design meeting 12:00")?.text == "A calendar with a meeting at noon.")
        #expect(AltTextPrompt.validated(kind: "screenshot", description: "A task board with team members and statuses.",
                                        recognizedText: "Tasks")?.text == "A task board with team members and statuses.")
    }

    @Test func descriptionsStayShort() {
        let first = "A chat window with a sidebar of channels and an open conversation."
        let long = first + " It also shows a long list of messages, reactions, attachments, avatars, timestamps, read receipts and other small details."
        #expect(AltTextPrompt.validated(kind: "screenshot", description: long, recognizedText: "") == AltText(text: first))
        let runOn = String(repeating: "a very long clause ", count: 12)
        #expect(AltTextPrompt.validated(kind: "screenshot", description: runOn, recognizedText: "") == nil)
    }

    @Test func tinyImagesSkipTheModel() {
        #expect(AltTextPrompt.isTooSmall(width: 1, height: 1))
        #expect(AltTextPrompt.isTooSmall(width: 60, height: 60))
        #expect(AltTextPrompt.isTooSmall(width: 400, height: 20))
        #expect(!AltTextPrompt.isTooSmall(width: 80, height: 80))
    }
}

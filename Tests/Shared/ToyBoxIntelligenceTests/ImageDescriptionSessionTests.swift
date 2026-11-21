@testable import ToyBoxIntelligence
import Foundation
import Testing

@MainActor
@Suite("Shared image descriptions")
struct ImageDescriptionSessionTests {
    let server = URL(string: "https://images-\(UUID().uuidString.lowercased()).invalid/prefix")!

    private func request(file: String = "/fixture/image.png",
                         priority: AltTextRequest.Priority = .visible) -> AltTextRequest {
        AltTextRequest(server: server, digest: "chart", fileURL: URL(filePath: file), priority: priority)
    }

    @Test func descriptionsRequireVoiceOverTheSettingAndAnAvailableModel() {
        let service = ScriptedIntelligence()
        #expect(TranscriptImageDescriptionSession.isActive(voiceOver: true, isOn: true, using: service))
        #expect(!TranscriptImageDescriptionSession.isActive(voiceOver: false, isOn: true, using: service))
        #expect(!TranscriptImageDescriptionSession.isActive(voiceOver: true, isOn: false, using: service))
        #expect(!TranscriptImageDescriptionSession.isActive(
            voiceOver: true, isOn: true, using: ScriptedIntelligence(availability: .unavailable(.modelNotReady))))
    }

    @Test func onlyCompletedDescriptionsHaveAnExplicitGeneratedAccessibilityValue() async {
        let descriptions = TranscriptImageDescriptionSession()
        #expect(descriptions.text(for: nil) == nil)
        #expect(descriptions.text(for: request()) == nil)
        #expect(TranscriptImageDescriptionSession.value(nil) == "")
        await descriptions.describe(request(), using: ScriptedIntelligence(text: "A chart of weekly signups."))
        #expect(descriptions.text(for: request()) == "A chart of weekly signups.")
        #expect(TranscriptImageDescriptionSession.value(descriptions.text(for: request()))
                == "Generated description: A chart of weekly signups.")
    }

    @Test func aDescriptionOutlivesItsCachedFileAndIsReusedAtFocusedPriority() async {
        let descriptions = TranscriptImageDescriptionSession()
        let service = ScriptedIntelligence(text: "A chart.")
        await descriptions.describe(request(), using: service)
        let focused = request(file: "/fixture/replaced.png", priority: .focused)
        #expect(descriptions.text(for: focused) == "A chart.")
        await descriptions.describe(focused, using: service)
        #expect(await service.count == 1)
    }

    @Test func anUnclearOrRefusedImageIsNotAskedForAgainInTheSameSession() async {
        let descriptions = TranscriptImageDescriptionSession()
        let service = ScriptedIntelligence()
        await descriptions.describe(request(), using: service)
        await descriptions.describe(request(priority: .focused), using: service)
        #expect(descriptions.text(for: request()) == nil)
        #expect(await service.count == 1)
        let anotherSession = TranscriptImageDescriptionSession()
        await anotherSession.describe(request(), using: service)
        #expect(await service.count == 2)
    }

    @Test func cancellationBeforeStartingNeverEnqueuesADescription() async {
        let descriptions = TranscriptImageDescriptionSession()
        let service = ScriptedIntelligence(text: "A chart.")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await descriptions.describe(request(), using: service)
        }
        await task.value
        #expect(await service.count == 0)
        #expect(descriptions.text(for: request()) == nil)
        await descriptions.describe(request(), using: service)
        #expect(descriptions.text(for: request()) == "A chart.")
    }

    @Test(arguments: ["The cancelled description.", nil] as [String?])
    func aCancelledTileDoesNotPublishOrMemoizeALateAnswerAndCanRetry(late: String?) async {
        let descriptions = TranscriptImageDescriptionSession()
        let service = ScriptedIntelligence(holding: true)
        let tile = Task { await descriptions.describe(request(), using: service) }
        await service.waitForCalls(1)
        tile.cancel()
        await service.answerAltText(late)
        await tile.value
        #expect(descriptions.text(for: request()) == nil)
        let retry = ScriptedIntelligence(text: "A chart.")
        await descriptions.describe(request(), using: retry)
        #expect(await retry.count == 1)
        #expect(descriptions.text(for: request()) == "A chart.")
    }
}

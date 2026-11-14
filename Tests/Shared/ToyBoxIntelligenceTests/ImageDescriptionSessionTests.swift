import ToyBoxIntelligence
import Foundation
import Testing

@MainActor
@Suite("Shared image descriptions")
struct ImageDescriptionSessionTests {
    let server = URL(string: "https://images-\(UUID().uuidString.lowercased()).invalid/prefix")!

    private func request(_ digest: String = "chart", server: URL? = nil,
                         file: String = "/fixture/image.png",
                         priority: AltTextRequest.Priority = .visible) -> AltTextRequest {
        AltTextRequest(server: server ?? self.server, digest: digest, fileURL: URL(filePath: file),
                       priority: priority)
    }

    @Test func descriptionsRequireVoiceOverTheSettingAndAnAvailableModel() {
        let service = ScriptedIntelligence()
        #expect(TranscriptImageDescriptionSession.isActive(voiceOver: true, isOn: true, using: service))
        #expect(!TranscriptImageDescriptionSession.isActive(voiceOver: false, isOn: true, using: service))
        #expect(!TranscriptImageDescriptionSession.isActive(voiceOver: true, isOn: false, using: service))
        for reason in [IntelligenceUnavailableReason.deviceNotEligible, .appleIntelligenceNotEnabled,
                       .modelNotReady, .unsupportedLanguage] {
            #expect(!TranscriptImageDescriptionSession.isActive(
                voiceOver: true, isOn: true, using: ScriptedIntelligence(availability: .unavailable(reason))))
        }
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

    @Test func normalizedServerAndDigestAreTheIdentityNotTheFileName() async {
        let descriptions = TranscriptImageDescriptionSession()
        let service = ScriptedIntelligence(text: "A chart.")
        await descriptions.describe(request(), using: service)
        let equivalentServer = URL(string: server.absoluteString.uppercased() + "/")!
        let equivalent = request(server: equivalentServer)
        #expect(descriptions.text(for: equivalent) == "A chart.")
        await descriptions.describe(equivalent, using: service)
        #expect(await service.count == 1)
        let otherServer = URL(string: server.absoluteString + "/another")!
        #expect(descriptions.text(for: request(server: otherServer)) == nil)
        #expect(descriptions.text(for: request("another-image")) == nil)
        await descriptions.describe(request(server: otherServer), using: service)
        await descriptions.describe(request("another-image"), using: service)
        #expect(await service.count == 3)
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

    @Test func aCancelledTileDoesNotPublishOrMemoizeALateAnswerAndCanRetry() async {
        let descriptions = TranscriptImageDescriptionSession()
        let service = ScriptedIntelligence(holding: true)
        let tile = Task { await descriptions.describe(request(), using: service) }
        await service.waitForCalls(1)
        tile.cancel()
        await service.answerAltText("The cancelled description.")
        await tile.value
        #expect(descriptions.text(for: request()) == nil)
        let focused = ScriptedIntelligence(text: "A chart.")
        await descriptions.describe(request(priority: .focused), using: focused)
        #expect(descriptions.text(for: request()) == "A chart.")
        #expect(await focused.count == 1)
    }

    @Test func aCancelledNilResultDoesNotPreventAReturningTileFromTryingAgain() async {
        let descriptions = TranscriptImageDescriptionSession()
        let service = ScriptedIntelligence(holding: true)
        let tile = Task { await descriptions.describe(request(), using: service) }
        await service.waitForCalls(1)
        tile.cancel()
        await service.answerAltText(nil)
        await tile.value
        let retry = ScriptedIntelligence(text: "A chart.")
        await descriptions.describe(request(), using: retry)
        #expect(await retry.count == 1)
        #expect(descriptions.text(for: request()) == "A chart.")
    }
}

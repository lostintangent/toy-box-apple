import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation
import SwiftUI
import Testing
@testable import ToyBoxMobile
import UIKit

@MainActor
@Suite("Gallery image descriptions")
struct GalleryIntelligenceTests {
    private func gallery() throws -> TranscriptGalleryPresenter {
        let presenter = TranscriptGalleryPresenter()
        let api = try ChannelAPI(serverURL: "https://gallery-\(UUID().uuidString.lowercased()).invalid/prefix")
        presenter.open(images: [
            ChannelAttachment(name: "chart.png", url: "/chart.png", mimeType: "image/png"),
            ChannelAttachment(name: "diagram.png", url: "/diagram.png", mimeType: "image/png"),
        ], at: 0, source: .init(messageID: "m1", sender: "Lead", timestamp: "2026-10-26T12:00:00Z"), api: api)
        return presenter
    }

    @Test func onlyLoadedImagesWithVoiceOverTheSettingAndAnAvailableModelAreRequested() throws {
        let gallery = try gallery()
        let session = try #require(gallery.session)
        let file = URL(filePath: "/fixture/chart.png")
        let service = GalleryDescriptionService()
        func request(file: URL? = file, voiceOver: Bool = true, isOn: Bool = true,
                     service: any ChannelIntelligenceService = service) -> AltTextRequest? {
            gallery.descriptionRequest(for: session, file: file, voiceOver: voiceOver, isOn: isOn, using: service)
        }
        #expect(request() != nil)
        #expect(request(file: nil) == nil)
        #expect(request(voiceOver: false) == nil)
        #expect(request(isOn: false) == nil)
        for reason in [IntelligenceUnavailableReason.deviceNotEligible, .appleIntelligenceNotEnabled,
                       .modelNotReady, .unsupportedLanguage] {
            #expect(request(service: GalleryDescriptionService(availability: .unavailable(reason))) == nil)
        }
    }

    @Test func theGalleryRequestsTheCachedOriginalAtFocusedPriorityAndKeepsItsLabel() throws {
        let gallery = try gallery()
        let session = try #require(gallery.session)
        let file = URL(filePath: "/fixture/chart.png")
        let request = try #require(gallery.descriptionRequest(
            for: session, file: file, voiceOver: true, isOn: true, using: GalleryDescriptionService()))
        let cached = try #require(ChannelAttachmentCache.destination(for: session.image, api: session.api))
        #expect(request.fileURL == file)
        #expect(request.digest == cached.deletingPathExtension().lastPathComponent)
        #expect(request.server == session.api.baseURL.absoluteString)
        #expect(request.priority == .focused)
        #expect(TranscriptGalleryPresenter.accessibilityLabel(session) == "Image 1 of 2 from Lead, chart.png")
    }

    @Test func returningToAnImageReusesItsDescriptionWithoutMixingUpPages() async throws {
        let gallery = try gallery()
        let descriptions = TranscriptImageDescriptionSession()
        let service = GalleryDescriptionService(text: "A chart of weekly signups.")
        func request() throws -> AltTextRequest {
            let session = try #require(gallery.session)
            return try #require(gallery.descriptionRequest(
                for: session, file: URL(filePath: "/fixture/\(session.image.name ?? "image")"),
                voiceOver: true, isOn: true, using: service))
        }
        let first = try request()
        await descriptions.describe(first, using: service)
        #expect(TranscriptImageDescriptionSession.value(descriptions.text(for: first))
                == "Generated description: A chart of weekly signups.")
        gallery.move(by: 1)
        let second = try request()
        #expect(first.digest != second.digest)
        #expect(descriptions.text(for: second) == nil)
        gallery.move(by: -1)
        let returned = try request()
        await descriptions.describe(returned, using: service)
        #expect(descriptions.text(for: returned) == "A chart of weekly signups.")
        #expect(await service.calls == 1)
    }

    @Test func aMissingDescriptionLeavesTheValueEmptyAndTheOriginalLabelIntact() async throws {
        let gallery = try gallery()
        let session = try #require(gallery.session)
        let service = GalleryDescriptionService()
        let request = try #require(gallery.descriptionRequest(
            for: session, file: URL(filePath: "/fixture/chart.png"), voiceOver: true, isOn: true, using: service))
        let descriptions = TranscriptImageDescriptionSession()
        await descriptions.describe(request, using: service)
        #expect(TranscriptImageDescriptionSession.value(descriptions.text(for: request)) == "")
        #expect(TranscriptGalleryPresenter.accessibilityLabel(session) == "Image 1 of 2 from Lead, chart.png")
    }

    @Test func departingAndClosedPagesImmediatelyLoseTheirRequest() throws {
        let gallery = try gallery()
        let first = try #require(gallery.session)
        let file = URL(filePath: "/fixture/chart.png")
        let service = GalleryDescriptionService()
        func request(_ page: TranscriptGalleryPresenter.Session) -> AltTextRequest? {
            gallery.descriptionRequest(for: page, file: file, voiceOver: true, isOn: true, using: service)
        }
        #expect(request(first) != nil)
        gallery.move(by: 1)
        let second = try #require(gallery.session)
        #expect(request(first) == nil)
        #expect(request(second) != nil)
        gallery.close()
        #expect(request(second) == nil)
        gallery.open(images: first.images, at: first.index, source: first.source, api: first.api)
        #expect(request(first) == nil)
        #expect(request(try #require(gallery.session)) != nil)
    }

    @Test func theNativeImageReceivesLateDescriptionsWithoutReloadingAndClearsThemWhenInactive() throws {
        let reader = TranscriptGalleryReader()
        let file = URL(filePath: "/fixture/chart.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let label = "Image 1 of 2 from Lead, chart.png"
        func canvas(_ value: String) -> TranscriptGalleryCanvas {
            TranscriptGalleryCanvas(image: image, size: image.size, file: file, title: label,
                                    descriptionValue: value, reader: reader, page: { _ in })
        }
        let host = UIHostingController(rootView: canvas(""))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        host.view.layoutIfNeeded()
        let originalCanvas = try #require(reader.canvas)
        let originalImage = try #require(originalCanvas.imageView.image)
        #expect(originalCanvas.imageView.accessibilityLabel == label)
        #expect(originalCanvas.imageView.accessibilityValue == "")

        host.rootView = canvas("Generated description: A yellow square.")
        host.view.layoutIfNeeded()
        let described = try #require(reader.canvas)
        #expect(described === originalCanvas)
        #expect(described.imageView.image === originalImage)
        #expect(described.imageView.accessibilityLabel == label)
        #expect(described.imageView.accessibilityValue == "Generated description: A yellow square.")
        #expect(described.imageView.isAccessibilityElement)
        #expect(described.imageView.accessibilityTraits.contains(.image))

        host.rootView = canvas("")
        host.view.layoutIfNeeded()
        #expect(described.imageView.accessibilityValue == "")
        #expect(described.imageView.accessibilityLabel == label)
    }
}

private actor GalleryDescriptionService: ChannelIntelligenceService {
    nonisolated let availability: IntelligenceAvailability
    let text: String?
    private(set) var calls = 0

    init(availability: IntelligenceAvailability = .available, text: String? = nil) {
        self.availability = availability
        self.text = text
    }
    func catchUp(_ request: CatchUpRequest) async -> CatchUpResult { .declined }
    func altText(_ request: AltTextRequest) async -> AltText? {
        calls += 1
        return text.map(AltText.init)
    }
}

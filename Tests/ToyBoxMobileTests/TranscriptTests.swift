import ChannelKit
import CoreGraphics
import Foundation
import Testing
@testable import ToyBoxMobile

@Suite("Mobile Transcript")
@MainActor
struct TranscriptTests {
    private let lead = ChannelAgent(id: "lead", name: "Lead")
    private let ada = ChannelAgent(id: "ada", name: "Ada")

    private func message(_ sequence: Int, _ sender: ChannelMessageSender, minute: Int = 0) -> ChannelMessage {
        ChannelMessage(id: "m\(sequence)", sequence: sequence,
                       timestamp: String(format: "2026-10-25T12:%02d:00Z", minute), sender: sender,
                       content: .text("Message \(sequence)"))
    }

    @Test func runsSplitIntoEntriesThatEachMarkTheirOwnSequence() {
        let messages = [
            message(1, .user),
            message(2, .agent("lead")),
            message(3, .agent("lead")),
            message(4, .agent("ada")),
        ]
        let rows = transcriptRows(messages, lead: lead, members: [ada], unreadAfter: 3,
                                  calendar: Calendar(identifier: .gregorian))
        let items = transcriptItems(rows)

        #expect(items.map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(items.map(\.order) == [0, 1, 2, 3])
        #expect(items.map(\.sequence) == [1, 2, 3, 4])
        #expect(items.map(\.spacing) == [0, TranscriptItem.runGap, TranscriptItem.entryGap, TranscriptItem.runGap])
        guard case .agent(_, _, let firstStarts) = items[1].content,
              case .agent(_, _, let secondStarts) = items[2].content else {
            Issue.record("Lead's run should become two agent entries.")
            return
        }
        #expect(firstStarts && !secondStarts)
        // A run's divider is drawn once, above its first entry.
        #expect(items[2].divider == nil)
        #expect(items[3].divider?.unread == true)
    }

    @Test func readingAPositionWaitsForAMeasuredRowInView() {
        let viewport = TranscriptScrollModel.Viewport(width: 386, height: 600, topInset: 0, bottomInset: 0)
        let scroll = TranscriptScroll()
        scroll.rows = (0..<10).map { .init(id: "r\($0)", order: $0) }
        for index in 0..<10 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        scroll.metrics = .init(viewport: viewport, origin: 400, documentEnd: 1000)
        #expect(scroll.update(.land(.end)) != nil)

        // An older page lands above, but the lazy stack hasn't reported it while it's on screen.
        scroll.rows = (0..<5).map { .init(id: "p\($0)", order: $0) }
            + (0..<10).map { .init(id: "r\($0)", order: $0 + 5) }
        for index in 0..<10 {
            scroll.measure("r\(index)", frame: CGRect(x: 0, y: 1000 + CGFloat(index) * 100, width: 386, height: 100))
        }
        scroll.metrics = .init(viewport: viewport, origin: 100, documentEnd: 2000)
        scroll.isReaderScrolling = true
        #expect(scroll.update() == nil)

        for index in 0..<5 { scroll.measure("p\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 200, width: 386, height: 200)) }
        #expect(scroll.update() != nil)
        guard case .reading(let anchor) = scroll.intent else {
            Issue.record("Scrolling should leave the reader where they are.")
            return
        }
        // The first measured row starting below the top holds the reader's place.
        #expect(anchor.row == "p1" && anchor.offset == 100)
    }

    @Test func theGalleryShowsOnlyTheMessagesImagesAndNeverWraps() throws {
        let attachments = [
            ChannelAttachment(name: "one.png", url: "/files/one.png", mimeType: "image/png"),
            ChannelAttachment(name: "notes.txt", url: "/files/notes.txt", mimeType: "text/plain"),
            ChannelAttachment(name: "diagram.svg", url: "/files/diagram.svg", mimeType: "image/svg+xml"),
            ChannelAttachment(name: "two.jpg", url: "/files/two.jpg", mimeType: "image/jpeg"),
            ChannelAttachment(name: "three.heic", url: "/files/three.heic"),
        ]
        let images = TranscriptGalleryPresenter.images(in: attachments)
        #expect(images.map(\.name) == ["one.png", "two.jpg", "three.heic"])

        let gallery = TranscriptGalleryPresenter()
        let api = try ChannelAPI(serverURL: "http://127.0.0.1:3210")
        let source = TranscriptGalleryPresenter.Source(messageID: "m1", sender: "Lead",
                                                       timestamp: "2026-10-25T12:00:00Z")
        gallery.open(images: images, at: 7, source: source, api: api)
        #expect(gallery.session?.index == 2)
        #expect(gallery.session?.canShowNext == false)
        gallery.move(by: 1)
        #expect(gallery.session?.index == 2)
        gallery.select(0)
        #expect(gallery.session?.index == 0)
        #expect(gallery.session?.direction == -1)
        #expect(gallery.session?.canShowPrevious == false)
        gallery.move(by: -1)
        #expect(gallery.session?.index == 0)
        #expect(gallery.session.map(TranscriptGalleryPresenter.accessibilityLabel) == "Image 1 of 3 from Lead, one.png")

        gallery.close()
        #expect(gallery.session == nil)
        gallery.open(images: [], at: 0, source: source, api: api)
        #expect(gallery.session == nil)
    }

    @Test func theGallerySubtitleCountsOnlySeveralImages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let sent = try #require(ChannelDates.date("2026-10-25T17:23:00Z"))
        let now = try #require(ChannelDates.date("2026-10-25T20:00:00Z"))
        func subtitle(_ index: Int, _ count: Int) -> String {
            TranscriptGalleryPresenter.subtitle(sentAt: sent, index: index, count: count, now: now, calendar: calendar)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(subtitle(1, 4) == "Today at 5:23 PM · 2 of 4")
        #expect(subtitle(0, 1) == "Today at 5:23 PM")
        #expect(TranscriptGalleryPresenter.subtitle(sentAt: nil, index: 2, count: 3) == "3 of 3")
    }
}

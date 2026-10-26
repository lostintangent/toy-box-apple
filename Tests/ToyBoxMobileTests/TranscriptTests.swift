@testable import ChannelClient
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

    @Test func onlyANewSendFollowsToTheBottom() {
        func attempt(_ id: String, _ phase: ChannelSendPhase) -> ChannelSendAttempt {
            ChannelSendAttempt(id: id, content: id, attachments: [], timestamp: "2026-10-25T12:00:00Z", phase: phase)
        }
        // The restored outbox lands after the unread landing and must not move the reader.
        #expect(!startsOwnPost(after: [], in: [attempt("old", .deliveryNotConfirmed), attempt("lost", .notSent)]))
        #expect(startsOwnPost(after: ["old"], in: [attempt("old", .notSent), attempt("new", .sending)]))
        // Send Again reuses its id, so it isn't a new post.
        #expect(!startsOwnPost(after: ["old"], in: [attempt("old", .sending)]))
    }
}

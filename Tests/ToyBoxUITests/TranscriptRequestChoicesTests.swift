@testable import ChannelClient
import ChannelKit
import Testing
import SwiftUI
import ToyBoxUI

/// Both apps show a request's suggested replies through this, so it decides for the Mac and the phone.
struct TranscriptRequestChoicesTests {
    private let replies = ["Ship it", "Hold for now", String(repeating: "x", count: 80)]

    @Test func aPendingRequestOffersItsRepliesInTheLeadsOrder() throws {
        let choices = try #require(TranscriptRequestChoices(request: request(replies: replies), attempts: [],
                                                            isConnected: true))
        #expect(choices.labels(for: 15, request: .pending) == replies)
        #expect(choices.canSend)
    }

    @Test func choicesWaitForTheConnectionToSend() throws {
        let choices = try #require(TranscriptRequestChoices(request: request(replies: replies), attempts: [],
                                                            isConnected: false))
        #expect(choices.labels(for: 15, request: .pending) == replies)
        #expect(!choices.canSend)
    }

    @Test func noRequestOrNoValidRepliesOffersNothing() {
        #expect(TranscriptRequestChoices(request: nil, attempts: [], isConnected: true) == nil)
        #expect(TranscriptRequestChoices(request: request(replies: nil), attempts: [], isConnected: true) == nil)
        #expect(TranscriptRequestChoices(request: request(replies: ["Only one"]), attempts: [],
                                         isConnected: true) == nil)
    }

    @Test func onlyThePendingRequestsOwnEntryShowsThem() throws {
        let choices = try #require(TranscriptRequestChoices(request: request(replies: replies), attempts: [],
                                                            isConnected: true))
        #expect(choices.labels(for: 15, request: .acknowledged).isEmpty)
        #expect(choices.labels(for: 15, request: nil).isEmpty)
        #expect(choices.labels(for: 14, request: .pending).isEmpty)
    }

    @Test(arguments: [ChannelSendPhase.sending, .notSent, .deliveryNotConfirmed, .confirmed])
    func aChosenReplyLeavesInEveryOutboxPhase(phase: ChannelSendPhase) {
        #expect(TranscriptRequestChoices(request: request(replies: replies),
                                         attempts: [attempt("Hold for now", phase: phase)],
                                         isConnected: true) == nil)
    }

    @Test func anUnrelatedSendKeepsTheChoices() {
        #expect(TranscriptRequestChoices(request: request(replies: replies),
                                         attempts: [attempt("Something else", phase: .notSent)],
                                         isConnected: true) != nil)
    }

    private func request(replies: [String]?) -> ChannelMessage {
        ChannelMessage(id: "m15", sequence: 15, timestamp: "2026-10-22T12:00:00Z", sender: .agent("channel"),
                       content: .text("Where should the library go?"), request: true, replies: replies)
    }

    private func attempt(_ content: String, phase: ChannelSendPhase) -> ChannelSendAttempt {
        ChannelSendAttempt(id: "a", content: content, attachments: [], timestamp: "2026-10-22T12:01:00Z",
                           phase: phase)
    }
}

/// The shared answer layout both transcripts and the Mac inbox use, measured through real renders.
@MainActor
struct ChoiceButtonLayoutTests {
    @Test func equalSharesFitOneRow() throws {
        // Three 60-point buttons with two 8-point gaps need 196 points.
        #expect(try height(of: [60, 60, 60], width: 196) == 20)
        #expect(try height(of: [60, 30, 60], width: 400) == 20)
    }

    @Test func aLongLabelBesideYesStacksInsteadOfTruncatingInItsShare() throws {
        // Summed, 30 + 300 + 8 fits 400, but two 300-point shares don't, so they stack.
        #expect(try height(of: [30, 300], width: 400) == 48)
        #expect(try height(of: [60, 60, 60], width: 195) == 76)
    }

    @Test func aLongTextLabelWrapsAtFullWidthWhenStacked() throws {
        let long = String(repeating: "Ship the build now ", count: 4)
        let renderer = ImageRenderer(content: ChoiceButtonLayout(spacing: 8) {
            Text("Yes")
            Text(long)
        }.font(.system(size: 13)).frame(width: 200))
        renderer.scale = 1
        let lineHeight = try #require(ImageRenderer(content: Text("Yes").font(.system(size: 13))).cgImage).height
        let image = try #require(renderer.cgImage)
        #expect(image.width == 200)
        #expect(image.height > lineHeight * 3)
    }

    private func height(of idealWidths: [CGFloat], width: CGFloat) throws -> Int {
        let renderer = ImageRenderer(content: ChoiceButtonLayout(spacing: 8) {
            ForEach(Array(idealWidths.enumerated()), id: \.offset) { _, ideal in
                Color.clear.frame(idealWidth: ideal, maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            }
        }.frame(width: width))
        renderer.scale = 1
        return try #require(renderer.cgImage).height
    }
}

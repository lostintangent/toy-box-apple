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
        #expect(choices.labels(for: 15) == replies)
        #expect(choices.canSend)
    }

    @Test func choicesWaitForTheConnectionToSend() throws {
        let choices = try #require(TranscriptRequestChoices(request: request(replies: replies), attempts: [],
                                                            isConnected: false))
        #expect(choices.labels(for: 15) == replies)
        #expect(!choices.canSend)
    }

    @Test func noRequestOrNoValidRepliesOffersNothing() {
        #expect(TranscriptRequestChoices(request: nil, attempts: [], isConnected: true) == nil)
        #expect(TranscriptRequestChoices(request: request(replies: nil), attempts: [], isConnected: true) == nil)
        #expect(TranscriptRequestChoices(request: request(replies: ["Only one"]), attempts: [],
                                         isConnected: true) == nil)
    }

    @Test func onlyTheRequestsOwnEntryShowsThem() throws {
        let choices = try #require(TranscriptRequestChoices(request: request(replies: replies), attempts: [],
                                                            isConnected: true))
        #expect(choices.labels(for: 14).isEmpty)
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

@MainActor
struct ChoiceFlowLayoutTests {
    @Test func buttonsKeepTheirNaturalWidthsOnOneLineWhenTheyFit() throws {
        // 60 + 6 + 30 + 6 + 50 is 152, so three fit a 152-point line.
        #expect(try height(of: [60, 30, 50], width: 152) == 20)
        let ideal = ImageRenderer(content: ChoiceFlowLayout(spacing: 6) { buttons([60, 30, 50]) })
        ideal.scale = 1
        #expect(try #require(ideal.cgImage).width == 152)
    }

    @Test func aButtonThatDoesNotFitStartsTheNextLine() throws {
        #expect(try height(of: [60, 30, 50], width: 151) == 46)
        #expect(try height(of: [300, 30, 50], width: 320) == 46)
        #expect(try height(of: [300, 300, 30], width: 320) == 72)
    }

    @Test func aLabelWiderThanTheLineWrapsAtFullWidth() throws {
        let long = String(repeating: "Ship the build now ", count: 4)
        let renderer = ImageRenderer(content: ChoiceFlowLayout(spacing: 6) {
            Text(long)
            Text("Reply")
        }.font(.system(size: 13)).frame(width: 200, alignment: .leading))
        renderer.scale = 1
        let lineHeight = try #require(ImageRenderer(content: Text("Yes").font(.system(size: 13))).cgImage).height
        let image = try #require(renderer.cgImage)
        #expect(image.width == 200)
        #expect(image.height > lineHeight * 3)
    }

    @Test func aLongChoiceWrapsInsideItsOwnSmallBorderedButton() throws {
        func height(_ replies: [String]?) throws -> Int {
            let request = ChannelMessage(id: "m1", sequence: 1, timestamp: "2026-10-22T12:00:00Z",
                                         sender: .agent("channel"), content: .text("?"), request: true,
                                         replies: replies)
            let choices = TranscriptRequestChoices(request: request, attempts: [], isConnected: true)
            let renderer = ImageRenderer(content: TranscriptRequestActions(
                spacing: 6, sequence: 1, choices: choices, replyHelp: "", onChoose: { _ in }, onReply: {})
                .controlSize(.small).font(.system(size: 11)).frame(width: 300, alignment: .leading))
            renderer.scale = 1
            return try #require(renderer.cgImage).height
        }
        let line = try height(nil)
        #expect(try height(["Yes", "Not yet"]) == line)
        // The long choice alone on two lines, above a line with Not yet and Reply.
        let long = "Ship the Mac build to GitHub Releases now and post the notes in the team channel"
        #expect(try height([long, "Not yet"]) > line * 2 + 6)
    }

    @Test func aWrappedChoiceFillsTheRowAndAShortOneKeepsItsLabelWidth() throws {
        func width(_ replies: [String]) throws -> Int {
            let request = ChannelMessage(id: "m1", sequence: 1, timestamp: "2026-10-22T12:00:00Z",
                                         sender: .agent("channel"), content: .text("?"), request: true,
                                         replies: replies)
            let choices = TranscriptRequestChoices(request: request, attempts: [], isConnected: true)
            let renderer = ImageRenderer(content: TranscriptRequestActions(
                spacing: 6, sequence: 1, choices: choices, replyHelp: "", onChoose: { _ in }, onReply: {})
                .controlSize(.small).font(.system(size: 11)))
            renderer.proposedSize = ProposedViewSize(width: 300, height: nil)
            renderer.scale = 1
            return try #require(renderer.cgImage).width
        }
        let long = "Ship the Mac build to GitHub Releases now and post the notes in the team channel"
        #expect(try width([long, "Not yet"]) == 300)
        #expect(try width(["Yes", "Not yet"]) < 200)
    }

    private func buttons(_ widths: [CGFloat]) -> some View {
        ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
            Color.clear.frame(width: width, height: 20)
        }
    }

    private func height(of widths: [CGFloat], width: CGFloat) throws -> Int {
        let renderer = ImageRenderer(content: ChoiceFlowLayout(spacing: 6) { buttons(widths) }
            .frame(width: width, alignment: .leading))
        renderer.scale = 1
        return try #require(renderer.cgImage).height
    }
}

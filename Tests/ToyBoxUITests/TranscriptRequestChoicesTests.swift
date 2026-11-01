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
        func height(_ choices: [String]) throws -> Int {
            let renderer = ImageRenderer(content: TranscriptRequestActions(
                .flow, sequence: 1, choices: choices, canSend: true, replyHelp: "", onChoose: { _ in }, onReply: {})
                .controlSize(.small).font(.system(size: 11)).frame(width: 300, alignment: .leading))
            renderer.scale = 1
            return try #require(renderer.cgImage).height
        }
        let line = try height(["Yes"])
        // One line of buttons, then the long choice alone on two lines above a line with Not yet and Reply.
        #expect(try height(["Yes", "Not yet"]) == line)
        let long = "Ship the Mac build to GitHub Releases now and post the notes in the team channel"
        #expect(try height([long, "Not yet"]) > line * 2 + 6)
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

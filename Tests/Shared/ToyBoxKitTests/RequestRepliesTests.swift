import Foundation
import Testing
@testable import ChannelKit

struct RequestRepliesTests {
    private func message(replies: Any? = nil, request: Bool? = true) throws -> ChannelMessage {
        var object: [String: Any] = [
            "id": "r1", "sequence": 15, "timestamp": "2026-10-03T20:00:00.000Z",
            "sender": ["type": "agent", "agentId": "studio-demo"],
            "content": "Where should the library sit?",
        ]
        if let request { object["request"] = request }
        if let replies { object["replies"] = replies }
        return try JSONDecoder().decode(ChannelMessage.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func aRequestDecodesItsRepliesInOrder() throws {
        let decoded = try message(replies: ["Near the entrance", "Beside the team desks"])
        #expect(decoded.replies == ["Near the entrance", "Beside the team desks"])
        #expect(decoded.suggestedReplies == ["Near the entrance", "Beside the team desks"])
    }

    @Test func aRequestWithoutRepliesOffersNone() throws {
        #expect(try message().replies == nil)
        #expect(try message().suggestedReplies.isEmpty)
        #expect(try message(replies: NSNull()).replies == nil)
    }

    @Test func repliesAreOmittedWhenAbsentAndKeptWhenPresent() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message())) as? [String: Any]
        #expect(plain?["replies"] == nil)

        let answered = try message(replies: ["Yes", "No"])
        let encoded = try JSONEncoder().encode(answered)
        #expect(try JSONDecoder().decode(ChannelMessage.self, from: encoded) == answered)
    }

    @Test func replyCountMustBeTwoToFour() throws {
        #expect(try message(replies: ["Only one"]).suggestedReplies.isEmpty)
        #expect(try message(replies: ["A", "B"]).suggestedReplies == ["A", "B"])
        #expect(try message(replies: ["A", "B", "C", "D"]).suggestedReplies == ["A", "B", "C", "D"])
        #expect(try message(replies: ["A", "B", "C", "D", "E"]).suggestedReplies.isEmpty)
        #expect(try message(replies: []).suggestedReplies.isEmpty)
    }

    @Test func labelsAreTrimmedAndNeverEmpty() throws {
        #expect(try message(replies: [" Yes ", "No\n"]).suggestedReplies == ["Yes", "No"])
        #expect(try message(replies: ["Yes", ""]).suggestedReplies.isEmpty)
        #expect(try message(replies: ["Yes", " \t "]).suggestedReplies.isEmpty)
    }

    @Test func labelsAreBoundedInUTF16UnitsLikeTheServer() throws {
        let eighty = String(repeating: "a", count: 80)
        #expect(try message(replies: [eighty, "Short"]).suggestedReplies == [eighty, "Short"])
        #expect(try message(replies: [eighty + "a", "Short"]).suggestedReplies.isEmpty)

        // Each emoji is two UTF-16 units, so forty of them fill the limit exactly.
        let forty = String(repeating: "\u{1F600}", count: 40)
        #expect(try message(replies: [forty, "Short"]).suggestedReplies.count == 2)
        #expect(try message(replies: [forty + "\u{1F600}", "Short"]).suggestedReplies.isEmpty)
    }

    @Test func repliesOnANonRequestNeverOffer() throws {
        let statement = try message(replies: ["Yes", "No"], request: false)
        #expect(statement.replies == ["Yes", "No"])
        #expect(statement.suggestedReplies.isEmpty)
        #expect(try message(replies: ["Yes", "No"], request: nil).suggestedReplies.isEmpty)
    }

    @Test func choiceActionsSendTheirTrimmedLabelByIndex() {
        let replies = [" Near the entrance ", "Beside the team desks"]
        #expect(SuggestedReplies(replies).label(forAction: SuggestedReplies.actionIdentifier(at: 0))
            == "Near the entrance")
        #expect(SuggestedReplies(replies).label(forAction: SuggestedReplies.actionIdentifier(at: 1))
            == "Beside the team desks")
    }

    @Test func choicesRejectNonCanonicalIndexes() {
        let replies = ["Yes", "No"]
        for action in ["reply-choice.01", "reply-choice.+1", "reply-choice.-0", "reply-choice.", "reply-choice.1 "] {
            #expect(SuggestedReplies(replies).label(forAction: action) == nil, "\(action)")
        }
    }

    @Test func choicesNeedTheSameValidLabelsAsTheCategory() {
        #expect(SuggestedReplies(["Only one"]).label(forAction: "reply-choice.0") == nil)
        #expect(SuggestedReplies(nil).label(forAction: "reply-choice.0") == nil)
        #expect(SuggestedReplies(["Yes", " "]).label(forAction: "reply-choice.0") == nil)
    }
}

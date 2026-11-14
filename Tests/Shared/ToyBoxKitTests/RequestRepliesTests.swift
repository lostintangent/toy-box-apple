import Foundation
import Testing
@testable import ToyBoxKit

struct RequestRepliesTests {
    private func message(replies: [String]? = nil, request: Bool? = true) throws -> ChannelMessage {
        var object: [String: Any] = [
            "id": "r1", "sequence": 15, "timestamp": "2026-10-03T20:00:00.000Z",
            "sender": ["type": "agent", "agentId": "studio-demo"],
            "content": "Where should the library sit?",
        ]
        if let request { object["request"] = request }
        if let replies { object["replies"] = replies }
        return try JSONDecoder().decode(ChannelMessage.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test(arguments: [
        (nil, []), ([], []), (["Only one"], []),
        (["A", "B"], ["A", "B"]), (["A", "B", "C", "D"], ["A", "B", "C", "D"]), (["A", "B", "C", "D", "E"], []),
        ([" Yes ", "No\n"], ["Yes", "No"]), (["Yes", ""], []), (["Yes", " \t "], []),
        ([String(repeating: "a", count: 80), "Short"], [String(repeating: "a", count: 80), "Short"]),
        ([String(repeating: "a", count: 81), "Short"], []),
        // Each emoji is two UTF-16 units, so forty of them fill the limit exactly.
        ([String(repeating: "\u{1F600}", count: 40), "Short"], [String(repeating: "\u{1F600}", count: 40), "Short"]),
        ([String(repeating: "\u{1F600}", count: 41), "Short"], []),
    ] as [([String]?, [String])])
    func aRequestOffersTwoToFourTrimmedLabelsBoundedInUTF16UnitsLikeTheServer(replies: [String]?,
                                                                                offered: [String]) throws {
        #expect(try message(replies: replies).suggestedReplies == offered)
    }

    @Test func repliesOnANonRequestNeverOffer() throws {
        let statement = try message(replies: ["Yes", "No"], request: false)
        #expect(statement.replies == ["Yes", "No"])
        #expect(statement.suggestedReplies.isEmpty)
        #expect(try message(replies: ["Yes", "No"], request: nil).suggestedReplies.isEmpty)
    }

    @Test(arguments: [
        (SuggestedReplies.actionIdentifier(at: 0), "Near the entrance"),
        (SuggestedReplies.actionIdentifier(at: 1), "Beside the team desks"),
        ("reply-choice.01", nil), ("reply-choice.+1", nil), ("reply-choice.-0", nil),
        ("reply-choice.", nil), ("reply-choice.1 ", nil),
    ] as [(String, String?)])
    func choiceActionsSendTheirTrimmedLabelOnlyByItsCanonicalIndex(action: String, label: String?) {
        #expect(SuggestedReplies([" Near the entrance ", "Beside the team desks"]).label(forAction: action) == label)
    }
}

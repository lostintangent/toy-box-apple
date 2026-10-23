import ChannelKit
import Foundation
import Testing
@testable import ChannelIntelligence

enum TestChannel {
    static let server = URL(string: "http://127.0.0.1:3210")!

    static func fixture(_ name: String) throws -> ChannelState {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ChannelState.self, from: Data(contentsOf: url))
    }

    /// The studio demo's agents with the given messages.
    static func state(_ messages: [ChannelMessage], requestSequence: Int? = nil) throws -> ChannelState {
        var state = try fixture("studio-demo")
        state.messages = messages
        state.channel.requestSequence = requestSequence
        state.request = messages.last { $0.request == true }
        return state
    }

    static func message(_ sequence: Int, from sender: String = "studio-demo", _ text: String,
                        request: Bool? = nil, images: Int = 0) -> ChannelMessage {
        ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T10:00:00.000Z",
                       sender: sender == "user" ? .user : .agent(sender), content: .text(text), request: request,
                       attachments: images == 0 ? nil : (0..<images).map { ChannelAttachment(name: "image-\($0).png") })
    }

    static func event(_ sequence: Int, _ content: ChannelSystemContent) -> ChannelMessage {
        ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T10:00:00.000Z",
                       sender: .system, content: .system(content))
    }

    static let paragraph = """
        Messages and reconnects now share one public Channel state, so a reconnect replays exactly what \
        the reader missed and nothing else. I also moved read receipts behind the same reducer, which \
        keeps them monotonic across tabs. The old polling path is gone, and the transcript no longer \
        flickers when a snapshot arrives late.
        """
}

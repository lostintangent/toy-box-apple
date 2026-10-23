import Foundation
import Testing
@testable import ChannelKit

extension ChannelAgent {
    static func lead(id: String) -> ChannelAgent {
        .lead(id: id, profile: .init(name: "Lead", role: "Test channel coordinator.",
                                     avatar: .init(mark: "M4 12H20", color: "#123456")))
    }
}

struct DomainTests {
    struct Trace: Decodable {
        var initial: ChannelState
        var steps: [Step]
        struct Step: Decodable {
            var name: String
            var event: ChannelObservationEvent
            var expected: ChannelState
        }
    }

    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func canonicalSnapshot() throws {
        let state = try JSONDecoder().decode(ChannelState.self, from: fixture("channel-snapshot"))
        #expect(state.lead.avatar?.color == "#0891b2")
        #expect(state.lead.avatar?.ink == nil)
        #expect(state.members.map(\.name) == ["Ada", "Finch", "Iris", "Juniper", "Kit", "Moss", "Nova", "Pixel"])
        #expect(state.request?.id == "fixture-request")
        #expect(state.channel.requestSequence == state.request?.sequence)
        #expect(state.members.first?.status?.workingOn == 9)
        #expect(state.presence["ada-engineer"]?.state == "working")
        #expect(state.messages.first(where: { $0.id == "fixture-progress" })?.reactions?.count == 2)
        #expect(state.artifacts.count == 2)
        #expect(state.routines.count == 1)
        #expect(state.channel.resolvedPreview?.url == "/demo-preview")
        for agent in state.agents {
            if let avatar = agent.avatar { #expect(throws: Never.self) { try SVGPath.parse(avatar.mark) } }
        }
    }

    @Test func canonicalTransitionConformance() throws {
        let trace = try JSONDecoder().decode(Trace.self, from: fixture("channel-transitions"))
        #expect(trace.steps.count == 25)
        var current = trace.initial
        for step in trace.steps {
            current = reduceChannelState(current, step.event)
            #expect(current == step.expected, Comment(rawValue: step.name))
        }
    }

    @Test func forwardCompatibleSystemContent() throws {
        let data = Data("""
        {"id":"new","sequence":1,"timestamp":"2026-10-01T00:00:00Z",
         "sender":{"type":"system"},"content":{"type":"future_kind","future_field":42,"member":"future identity"}}
        """.utf8)
        let message = try JSONDecoder().decode(ChannelMessage.self, from: data)
        #expect(message.system?.type == "future_kind")
        #expect(message.system?.unknownFields?["member"] == .string("future identity"))
    }

    @Test func localPostDoesNotAcknowledgeRequest() throws {
        let trace = try JSONDecoder().decode(Trace.self, from: fixture("channel-transitions"))
        let message = ChannelMessage(id: "optimistic", sequence: 0, timestamp: "2026-10-01T00:00:00Z",
                                     sender: .user, content: .text("Reply"))
        let event = ChannelObservationEvent(type: "message", message: message)
        let next = reduceChannelState(trace.initial, event)
        #expect(next.revision == trace.initial.revision)
        #expect(next.channel == trace.initial.channel)
        #expect(next.request == trace.initial.request)
        #expect(next.messages.last?.id == "optimistic")
        #expect(reduceChannelState(next, event) == next)
    }
}

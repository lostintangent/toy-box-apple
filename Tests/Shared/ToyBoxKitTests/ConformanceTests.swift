import Foundation
import Testing
@testable import ToyBoxKit

extension ChannelAgent {
    static func lead(id: String) -> ChannelAgent {
        .lead(id: id, profile: .init(name: "Lead", role: "Test channel coordinator.",
                                     avatar: .init(mark: "M4 12H20", color: "#123456")))
    }
}

struct ConformanceTests {
    struct Trace: Decodable {
        var initial: ChannelState
        var steps: [Step]
        struct Step: Decodable {
            var name: String
            var event: ChannelSubscriptionEvent
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
        #expect(state.messages.first(where: { $0.id == "fixture-progress" })?.reactions?.count == 2)
        #expect(state.artifacts.count == 2)
        #expect(state.routines.count == 1)
        #expect(state.channel.preview == .init(kind: "url", url: "/demo-preview"))
        #expect(state.bookmarks == [])
        for agent in state.agents {
            if let avatar = agent.avatar { #expect(throws: Never.self) { try SVGPath.parse(avatar.mark) } }
        }
    }

    /// The snapshot's `presence` is what Toy Box derived from each agent's status and whether it was
    /// running, so the rule rebuilds it from the agents it lists as working.
    @Test func presenceMatchesTheServersFromTheRunningAgents() throws {
        struct Served: Decodable { var presence: [String: ChannelAgentPresence] }
        let data = try fixture("channel-snapshot")
        let state = try JSONDecoder().decode(ChannelState.self, from: data)
        let served = try JSONDecoder().decode(Served.self, from: data).presence
        let running = Set(served.filter { $0.value.state == "working" }.keys)
        #expect(running == ["ada-engineer", "iris-systems", "moss-reviewer", "pixel-designer"])
        var derived: [String: ChannelAgentPresence] = [:]
        for agent in state.agents { derived[agent.id] = agent.presence(isRunning: running.contains(agent.id)) }
        #expect(derived == served)
    }

    @Test func presenceTrustsRunningOverAStaleStatus() {
        var agent = ChannelAgent(id: "ada", name: "Ada", status: .init(state: "working", text: "Compiling", workingOn: 9))
        #expect(agent.presence(isRunning: true) == .init(state: "working", text: "Compiling"))
        #expect(agent.presence(isRunning: false) == .init(state: "idle"))
        agent.status = .init(state: "waiting", text: "Moss's review", wakeAt: "2026-10-03T20:20:00.000Z")
        #expect(agent.presence(isRunning: true) == .init(state: "working"))
        #expect(agent.presence(isRunning: false) == agent.status)
        agent.status = nil
        #expect(agent.presence(isRunning: true) == .init(state: "working"))
        #expect(agent.presence(isRunning: false) == .init(state: "idle"))
    }

    @Test func canonicalTransitionConformance() throws {
        let trace = try JSONDecoder().decode(Trace.self, from: fixture("channel-transitions"))
        #expect(trace.steps.count == 28)
        var current = trace.initial
        for step in trace.steps {
            current = current.applying(step.event)
            #expect(current == step.expected, Comment(rawValue: step.name))
        }
    }

    @Test func taskTimingDecodesRecursivelyAndRemainsOptional() throws {
        let data = Data("""
        {"id":"parent","title":"Parent","status":"in_progress","startedAt":"2026-10-24T10:00:00Z",
         "checkInAt":"2026-10-24T11:00:00Z","children":[
           {"id":"child","title":"Child","status":"blocked","startedAt":"2026-10-24T10:15:00Z"},
           {"id":"legacy","title":"Legacy","status":"pending"}
         ]}
        """.utf8)
        let task = try JSONDecoder().decode(ChannelTask.self, from: data)
        #expect(task.startedAt == "2026-10-24T10:00:00Z")
        #expect(task.checkInAt == "2026-10-24T11:00:00Z")
        #expect(task.children?.first?.startedAt == "2026-10-24T10:15:00Z")
        #expect(task.children?.first?.checkInAt == nil)
        #expect(task.children?.last?.startedAt == nil)
        #expect(task.children?.last?.checkInAt == nil)
        #expect(try JSONDecoder().decode(ChannelTask.self, from: JSONEncoder().encode(task)) == task)
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

    @Test func wireDatesAcceptOptionalFractionsAndOffsets() throws {
        let whole = Date(timeIntervalSince1970: 1_792_832_400)
        for (value, fraction) in [
            ("2026-10-24T09:00:00Z", 0.0),
            ("2026-10-24T09:00:00.000Z", 0.0),
            ("2026-10-24T09:00:00.125Z", 0.125),
            ("2026-10-24T09:00:00.123456Z", 0.123456),
            ("2026-10-24T09:00:00.123456789Z", 0.123456789),
            ("2026-10-24T11:00:00+02:00", 0.0),
            ("2026-10-24T03:30:00.125-05:30", 0.125),
        ] {
            let date = try #require(try? Date(value, strategy: .iso8601))
            #expect(abs(date.timeIntervalSince(whole) - fraction) < 0.000001, Comment(rawValue: value))
        }
        for value in ["", "not-a-date", "2026-10-24T09:00:00.invalidZ"] {
            #expect((try? Date(value, strategy: .iso8601)) == nil)
        }
    }
}

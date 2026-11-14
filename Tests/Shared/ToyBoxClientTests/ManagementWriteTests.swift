import ToyBoxKit
import Foundation
import Testing
@testable import ToyBoxClient

@Suite(.timeLimit(.minutes(1)))
struct ManagementWriteTests {
    enum Write: CaseIterable, Sendable {
        case createChannel, editChannel, deleteChannel, createMember, editMember, removeMember, runRoutine, deleteRoutine, removeArtifact

        func perform(using api: ChannelAPI) async throws {
            switch self {
            case .createChannel:
                _ = try await api.createChannel(.init(name: "Test", model: testState().channel.model))
            case .editChannel:
                _ = try await api.editChannel(id: "test", changes: .init(name: "Edited"))
            case .deleteChannel: try await api.deleteChannel(id: "test")
            case .createMember:
                _ = try await api.createMember(channelId: "test", input: .init(name: "Ada"))
            case .editMember:
                _ = try await api.editMember(channelId: "test", agentId: "member", changes: .init(model: .clear))
            case .removeMember: try await api.removeMember(channelId: "test", agentId: "member")
            case .runRoutine: try await api.runRoutine(channelId: "test", routineId: "daily")
            case .deleteRoutine: try await api.deleteRoutine(channelId: "test", routineId: "daily")
            case .removeArtifact:
                try await api.removeArtifact(channelId: "test", artifactId: "machine:/demo/Plan.md")
            }
        }
    }

    @Test func clearOverrideSendsNullAndReceiptAndEventRemoveTheModel() async throws {
        let memberData = Data(#"{"id":"member","name":"Ada","channelId":"test"}"#.utf8)
        let mock = MockTransport { _, _ in
            MockResponse(body: Data(#"{"id":"member","name":"Ada","channelId":"test"}"#.utf8))
        }
        let api = try mock.api()
        let receipt = try await api.editMember(channelId: "test", agentId: "member", changes: .init(model: .clear))
        let request = try #require(mock.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/v1/channels/test/members/member")
        let body = try JSONDecoder().decode(JSONValue.self, from: requestBody(request))
        #expect(body == .object(["model": .null]))
        #expect(receipt.model == nil)
        var state = testState()
        state.members = [ChannelAgent(id: "member", name: "Ada", channelId: "test",
                                      model: .init(provider: "copilot", name: "explicit"))]
        let cleared = try JSONDecoder().decode(ChannelAgent.self, from: memberData)
        let reduced = state.applying(.init(type: "member", revision: 1, member: cleared))
        #expect(reduced.members.first?.model == nil)
        #expect(reduced.members.first?.id == "member")
    }

    @Test(arguments: [500, 422])
    func everyManagementWriteIsSingleAttemptAndPreservesTheServerError(status: Int) async throws {
        for write in Write.allCases {
            let mock = MockTransport { _, _ in
                MockResponse(status: status, body: Data(#"{"error":"Unable to change Channel."}"#.utf8))
            }
            let api = try mock.api()
            await #expect(throws: ChannelAPIError.http(status: status, message: "Unable to change Channel.")) {
                try await write.perform(using: api)
            }
            #expect(mock.requests.count == 1)
        }
    }

    @Test func explicitCrossProviderAssignmentStillSurfacesTheDomainRejection() async throws {
        let message = "A member's provider cannot change without losing its session history."
        let mock = MockTransport { _, _ in
            try .json(["error": message], status: 422)
        }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.http(status: 422, message: message)) {
            try await api.editMember(channelId: "test", agentId: "member",
                                     changes: .init(model: .set(.init(provider: "claude", name: "sonnet"))))
        }
        #expect(mock.requests.count == 1)
        let request = try #require(mock.requests.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: requestBody(request))
        #expect(body == .object(["model": .object(["provider": .string("claude"), "name": .string("sonnet")])]))
    }
}

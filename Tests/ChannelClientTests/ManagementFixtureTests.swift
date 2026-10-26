import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

struct ManagementFixtureTests {
    static var fixtureURL: String? { ProcessInfo.processInfo.environment["TOY_BOX_MANAGEMENT_DEMO_URL"] }

    @Test(.enabled(if: fixtureURL != nil), .timeLimit(.minutes(1)))
    func realManagementRoutesDecodeThroughTheClient() async throws {
        let api = try ChannelAPI(serverURL: #require(Self.fixtureURL))
        guard api.baseURL.port == 3240, ["localhost", "127.0.0.1"].contains(api.baseURL.host) else {
            throw ChannelAPIError.invalidServerURL
        }
        let catalog = try await api.catalog()
        #expect(catalog.lead.name.isEmpty == false)
        _ = try #require(catalog.channels.first { $0.id == "management-demo" })
        let models = try await api.models()
        var configured = try #require(models.defaultModel)
        configured.options["reasoningEffort"] = .string("high")
        let channel = try await api.createChannel(.init(name: "Client fixture \(UUID())", purpose: "Private",
                                                       model: configured))
        do {
            let initial = try await api.snapshot(channelId: channel.id)
            #expect(initial.channel.id == channel.id)
            #expect(initial.channel.model == configured)
            #expect(initial.messages.isEmpty)
            #expect(initial.members.isEmpty)
            #expect(initial.channel.tasks.isEmpty)
            #expect(initial.revision == 0)
            #expect(initial.channel.seenThrough == 0)
            let edited = try await api.editChannel(id: channel.id, changes: .init(name: "Edited", purpose: .clear))
            #expect(edited.name == "Edited")
            #expect(edited.purpose == nil)
            let member = try await api.createMember(channelId: channel.id, input: .init(name: "Ada", role: "Build"))
            #expect(member.model == nil)
            let choices = try await api.memberModels(channelId: channel.id, agentId: member.id)
            #expect(choices.defaultModel == configured)
            let overridden = try await api.editMember(channelId: channel.id, agentId: member.id,
                                                      changes: .init(model: .set(configured)))
            #expect(overridden.model == configured)
            let inherited = try await api.editMember(channelId: channel.id, agentId: member.id,
                                                     changes: .init(model: .clear))
            #expect(inherited.model == nil)
            try await api.removeMember(channelId: channel.id, agentId: member.id)
            let final = try await api.snapshot(channelId: channel.id)
            #expect(final.members.isEmpty)
            #expect(final.channel.name == "Edited")
            #expect(final.channel.purpose == nil)
            #expect(try await api.history(channelId: channel.id, before: 1).messages.isEmpty)
            #expect(try await api.markRead(channelId: channel.id, sequence: 0) == 0)
        } catch {
            do { try await api.deleteChannel(id: channel.id) }
            catch { Issue.record("Could not remove the private integration channel: \(error)") }
            throw error
        }
        try await api.deleteChannel(id: channel.id)
        #expect(try await api.catalog().channels.contains { $0.id == channel.id } == false)
    }
}

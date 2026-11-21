import ToyBoxKit
import Foundation
import Testing
@testable import ToyBoxClient

@MainActor
struct ManagementPresenterTests {
    /// Answers a member write with Moss, or `memberStatus` with an error, and anything else with a 404.
    private func transport(memberStatus: Int = 201) -> MockTransport {
        MockTransport { request, _ in
            guard request.url?.path.contains("/members") == true else { return MockResponse(status: 404) }
            return memberStatus == 201
                ? try .json(ChannelAgent(id: "moss", name: "Moss"), status: 201)
                : try .json(["error": "Management failed."], status: memberStatus)
        }
    }

    private func connectedStore(_ mock: MockTransport) throws -> ChannelStore {
        let store = ChannelStore(id: "test", api: try mock.api())
        _ = try store.apply(.init(type: "snapshot", state: testState(revision: 1)))
        return store
    }

    @Test func aSaveClosesOnlyTheFlowThatSentIt() async throws {
        let catalog = ChannelCatalogStore(api: try transport().api())
        let presenter = ManagementPresenter()
        let channel = try #require(catalog.target("channel"))
        presenter.present(.addMember(channel, name: "Moss"))
        #expect(presenter.memberForm.name == "Moss")
        await presenter.save(on: catalog)
        #expect(presenter.flow == nil)

        // Presenting the same flow again is a new visit with fresh entries, which the old save leaves open.
        presenter.present(.addMember(channel, name: "Moss"))
        let save = Task.immediate { await presenter.save(on: catalog) }
        presenter.flow = nil
        presenter.present(.addMember(channel, name: "Moss"))
        presenter.memberForm.role = "Unsaved"
        await save.value
        #expect(presenter.flow == .addMember(channel, name: "Moss"))
        #expect(presenter.memberForm.role == "Unsaved" && !presenter.isPending)

        // New Channel's Server menu keeps its entries.
        presenter.present(.newChannel(server: "http://127.0.0.1:3210"))
        presenter.channelForm.name = "Workshop"
        presenter.flow = .newChannel(server: "http://127.0.0.1:3211")
        #expect(presenter.channelForm.name == "Workshop")
    }

    @Test func aSavedEditShowsThroughTheCatalogStreamItLeavesOpen() async throws {
        let channel = testState().channel
        let edited = { var edited = channel; edited.name = "Edited"; return edited }()
        let mock = MockTransport(catalogOnly: true) { request, _ in
            request.httpMethod == "PATCH"
                ? try .json(edited)
                : try .catalogStream(ChannelCatalog(lead: testLeadProfile, channels: [channel]))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually { catalog.phase == .connected }
        let presenter = ManagementPresenter()
        presenter.present(.editChannel(try #require(catalog.target(channel.id))))
        presenter.channelForm = ChannelForm(ChannelDetails(channel))
        presenter.channelForm.name = "Edited"
        await presenter.save(on: catalog)
        #expect(presenter.flow == nil)

        #expect(mock.sendPendingBody(try catalogFrame("channel.upserted", ("channel", edited))) == 1)
        try await eventually { catalog.channels.map(\.name) == ["Edited"] }
        #expect(mock.requests.map(\.httpMethod) == ["GET", "PATCH"])
    }

    @Test func aFailedWriteKeepsItsFlowAndEntries() async throws {
        let catalog = ChannelCatalogStore(api: try transport(memberStatus: 500).api())
        let presenter = ManagementPresenter()
        let target = try #require(catalog.target("channel"))
        let editing = ManagementFlow.editMember(target, agentId: "moss")
        presenter.present(editing)
        presenter.memberForm.name = "Unsaved"
        presenter.focus = .role

        // Removing from Edit Agent asks beside it, and a failure only says so.
        let removal = ManagementFlow.removeMember(target, agentId: "moss")
        await presenter.delete(removal, on: catalog)
        #expect(presenter.deletion?.flow == removal && presenter.deletion?.failed == true)
        #expect(presenter.flow == editing && presenter.memberForm.name == "Unsaved")

        await presenter.save(on: catalog)
        #expect(presenter.flow == editing && presenter.error == "Management failed.")
        #expect(presenter.memberForm.name == "Unsaved" && presenter.focus == .role && !presenter.isPending)
    }

    @Test func eachFlowWritesToItsOwnServer() throws {
        let first = ChannelCatalogStore(api: try ChannelAPI(serverURL: "http://127.0.0.1:3210"))
        let second = ChannelCatalogStore(api: try ChannelAPI(serverURL: "http://127.0.0.1:3211"))
        let editing = ManagementFlow.editChannel(try #require(second.target("channel")))
        let creating = ManagementFlow.newChannel(server: "http://127.0.0.1:3211/")
        #expect(editing.catalog(in: [first, second]) === second)
        #expect(creating.catalog(in: [first, second]) === second)
        // Once Settings removes the server, its channel has nowhere to write, and New Channel starts on the first.
        #expect(editing.catalog(in: [first]) == nil)
        #expect(creating.catalog(in: [first]) === first)
    }

    @Test func inlineCreationReturnsTheMemberWithoutDismissingAnUnrelatedSheet() async throws {
        let mock = transport()
        let store = try connectedStore(mock)
        let presenter = ManagementPresenter()
        let target = try #require(store.target)
        presenter.present(.addMember(target, name: "Finch"))
        let member = try await presenter.createMentionMember(name: "Moss", store: store)
        #expect(member == ChannelAgent(id: "moss", name: "Moss"))
        #expect(presenter.flow == .addMember(target, name: "Finch"))
        #expect(mock.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
                == ["POST /api/v1/channels/test/members"])
    }

    @Test(arguments: [true, false])
    func inlineCreationRefusesAnUnconnectedStoreOrAnInvalidNameBeforeWriting(connected: Bool) async throws {
        let mock = transport()
        let store = connected ? try connectedStore(mock) : ChannelStore(id: "test", api: try mock.api())
        let name = connected ? " lead " : "Moss"
        let expected: ChannelAPIError = connected
            ? .invalidMessage(try #require(ChannelAgent.nameError(name, agents: store.roster)))
            : .disconnected
        let presenter = ManagementPresenter()
        let target = try #require(store.target)
        presenter.present(.addMember(target, name: "Finch"))
        await #expect(throws: expected) {
            _ = try await presenter.createMentionMember(name: name, store: store)
        }
        #expect(presenter.flow == .addMember(target, name: "Finch"))
        #expect(mock.requests.isEmpty)
    }
}

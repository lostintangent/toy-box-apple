import Foundation
import Testing
@testable import ChannelKit

struct ChannelReactionTests {
    let ada = ChannelAgent(id: "ada", name: "Ada")
    let finch = ChannelAgent(id: "finch", name: "Finch")

    @Test func activityReactionsRequireWorkingPresenceAndDurableTargets() {
        var agent = ada
        agent.status = .init(state: "working", text: "Reviewing", lookingAt: 12, workingOn: 12)
        let working = [agent].statusReactions(presence: ["ada": .init(state: "working")])
        #expect(working[12]?.map(\.reaction) == ["looking", "working"])
        #expect([agent].statusReactions(presence: [:]).isEmpty)
        agent.status = .init(state: "waiting", text: "Waiting", lookingAt: 12)
        #expect([agent].statusReactions(presence: ["ada": .init(state: "working")]).isEmpty)
    }

    @Test func statusReactionsGroupBySequenceInAgentOrder() {
        var ada = ada
        var finch = finch
        ada.status = .init(state: "working", text: "Reviewing", lookingAt: 12, workingOn: 14)
        finch.status = .init(state: "working", text: "Building", lookingAt: 14, workingOn: 14)
        let presence: [String: ChannelAgentPresence] = ["ada": .init(state: "working"), "finch": .init(state: "working")]
        let reactions = [ada, finch].statusReactions(presence: presence)
        #expect(reactions[12]?.map(\.agentId) == ["ada"])
        #expect(reactions[14]?.map { "\($0.agentId) \($0.reaction)" } == ["ada working", "finch looking", "finch working"])
        #expect([ada, finch].statusReactions(presence: [:]).isEmpty)
    }
}

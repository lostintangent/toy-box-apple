import Foundation
import Testing
@testable import ToyBoxKit

struct ManagementValidationTests {
    @Test func emptyAndOversizedMemberNamesAreRejected() {
        #expect(ChannelAgent.nameError(" \n ", agents: []) == "Enter an agent name.")
        #expect(ChannelAgent.nameError(String(repeating: "a", count: 80), agents: []) == nil)
        #expect(ChannelAgent.nameError(String(repeating: "a", count: 81), agents: []) != nil)
        #expect(ChannelAgent.nameError(String(repeating: "\u{1F680}", count: 40), agents: []) == nil)
        #expect(ChannelAgent.nameError(String(repeating: "\u{1F680}", count: 41), agents: []) != nil)
    }

    @Test func duplicateMentionsUseTheCanonicalHandle() {
        let agents = [ChannelAgent.lead(id: "channel"), ChannelAgent(id: "member", name: "Caf\u{00E9} Critic")]
        #expect(ChannelAgent.nameError(" lead ", agents: agents) != nil)
        #expect(ChannelAgent.nameError("CAFE-critic", agents: agents) != nil)
        #expect(ChannelAgent.nameError("Caf\u{00E9} Critic", agents: agents, excludingID: "member") == nil)
        #expect(ChannelAgent.nameError("Another critic", agents: agents) == nil)
        #expect(ChannelAgent.nameError("CAFE-critic", agents: [
            .init(id: "deleted", name: "Caf\u{00E9} Critic", deleted: true)
        ]) == "Another agent is already mentioned as @cafe-critic.")
    }

    @Test func editorFieldLimitsUseUTF16AndLeaveRequiredFieldPromptsToTheForm() {
        for (check, limit) in [
            (Channel.nameError, 100),
            (Channel.purposeError, 12_000),
            (Channel.directoryError, 4_096),
        ] {
            #expect(check("") == nil)
            #expect(check(String(repeating: "a", count: limit)) == nil)
            #expect(check(String(repeating: "a", count: limit + 1)) != nil)
            #expect(check(String(repeating: "\u{1F680}", count: limit / 2)) == nil)
            #expect(check(String(repeating: "\u{1F680}", count: limit / 2 + 1)) != nil)
        }
    }

    @Test func anExistingRoleCannotBeEmptiedButANewRoleMayBeOmitted() {
        #expect(ChannelAgent.roleError("", existingRole: nil) == nil)
        #expect(ChannelAgent.roleError("", existingRole: "") == "An existing role can't be emptied.")
        #expect(ChannelAgent.roleError("", existingRole: "Existing") == "An existing role can't be emptied.")
        #expect(ChannelAgent.roleError(String(repeating: "\u{1F680}", count: 4_000), existingRole: "Old") == nil)
        #expect(ChannelAgent.roleError(String(repeating: "a", count: 8_001), existingRole: nil)
                == "Roles are limited to 8,000 characters.")
    }
}

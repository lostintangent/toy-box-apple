import ChannelKit
import Testing
import ToyBoxUI

@MainActor
struct ChannelInteractionTests {
    @Test func hostsChooseInspectorVisibilityAndReplyKeepsItsSource() {
        let phone = ChannelInteraction(isInspectorPresented: false)
        #expect(!phone.isInspectorPresented)
        #expect(ChannelInteraction().isInspectorPresented)
        let agent = ChannelAgent(id: "ada", name: "Ada")
        phone.reply(to: agent, sequence: 42)
        #expect(phone.replyRequest?.sequence == 42)
        let token = phone.replyRequest?.token
        phone.reply(to: agent)
        #expect(phone.replyRequest?.sequence == nil)
        #expect(phone.replyRequest?.token != token)
        #expect(phone.replyRequest?.agent == agent)
    }

    @Test func consumingAnOldRevealCannotDiscardTheNewerRequest() {
        let interaction = ChannelInteraction()
        interaction.reveal(sequence: 20)
        let old = interaction.revealRequestToken
        interaction.reveal(sequence: 30)
        interaction.consumeRevealRequest(old)
        #expect(interaction.revealRequest?.sequence == 30)
        interaction.consumeRevealRequest(interaction.revealRequestToken)
        #expect(interaction.revealRequest == nil)
    }
}

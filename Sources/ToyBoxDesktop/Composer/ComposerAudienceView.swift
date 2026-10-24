import ChannelKit
import SwiftUI

struct ComposerAudienceView: View {
    let text: String
    let agents: [ChannelAgent]
    let acknowledgesRequest: Bool
    var hasBackground = true

    var body: some View {
        if let lead = agents.first {
            audience(lead: lead, members: Array(agents.dropFirst()))
        }
    }

    private func audience(lead: ChannelAgent, members: [ChannelAgent]) -> some View {
        let recipients = resolveChannelAudience(content: text, sender: .user, lead: lead, members: members,
                                                acknowledgedRequest: acknowledgesRequest)
        let names = recipients.map(\.name).joined(separator: ", ")
        let label = recipients.isEmpty ? "No one will be notified"
            : "To \(channelAudienceLabel(recipients, reachableCount: members.count + 1))"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                if recipients.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ForEach(recipients.prefix(3)) { agent in AgentAvatarView(agent: agent, size: 16) }
                }
                Text(label).lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 4) {
                if let first = recipients.first {
                    AgentAvatarView(agent: first, size: 16)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(recipients.isEmpty ? "No recipients" : "\(recipients.count)")
            }
        }
        .padding(.horizontal, hasBackground ? 7 : 0)
        .frame(height: 24)
        .background(hasBackground
                    ? (recipients.isEmpty ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.08))
                    : Color.clear, in: Capsule())
        .foregroundStyle(recipients.isEmpty ? Color.primary : .secondary)
        .help(recipients.isEmpty ? label : "Notifies \(names)")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(recipients.isEmpty ? label : "To \(names)")
    }
}

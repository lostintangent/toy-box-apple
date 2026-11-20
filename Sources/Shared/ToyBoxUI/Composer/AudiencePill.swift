import ToyBoxKit
import SwiftUI

/// Who a message will notify, as the phone's composer and share sheet show it.
public struct AudiencePill: View {
    let text: String
    let agents: [ChannelAgent]
    let acknowledgesRequest: Bool
    /// When false, only the avatars or the orange warning show. The full label stays in
    /// accessibility and the context menu.
    let showsLabel: Bool

    /// `agents` starts with the channel's lead.
    public init(
        text: String,
        agents: [ChannelAgent],
        acknowledgesRequest: Bool,
        showsLabel: Bool = true
    ) {
        self.text = text
        self.agents = agents
        self.acknowledgesRequest = acknowledgesRequest
        self.showsLabel = showsLabel
    }

    public var body: some View {
        if let lead = agents.first {
            let recipients = AgentMentions(parsing: text).audience(
                sender: .user, lead: lead, members: Array(agents.dropFirst()),
                acknowledgedRequest: acknowledgesRequest
            )
            let names = recipients.map(\.name).joined(separator: ", ")
            let label = recipients.isEmpty ? "No one will be notified"
                : "To \(AgentMentions.audienceLabel(for: recipients, reachableCount: agents.count))"
            Group {
                if showsLabel {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            avatars(recipients)
                            Text(label).lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        HStack(spacing: 4) {
                            avatars(Array(recipients.prefix(1)))
                            Text(recipients.isEmpty ? "No recipients" : "\(recipients.count)")
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    HStack(spacing: 4) {
                        avatars(recipients)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(minHeight: 24)
            .background(recipients.isEmpty ? AnyShapeStyle(Color.orange.opacity(0.1)) : AnyShapeStyle(.fill.secondary),
                        in: Capsule())
            .foregroundStyle(recipients.isEmpty ? Color.primary : ChannelInk.secondary)
            .frame(minHeight: 44)
            .contextMenu {
                Text(recipients.isEmpty ? label : "Notifies \(names)")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(recipients.isEmpty ? label : "To \(names)")
        }
    }

    @ViewBuilder
    private func avatars(_ recipients: [ChannelAgent]) -> some View {
        if recipients.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            ForEach(recipients.prefix(3)) { agent in AgentAvatarView(agent: agent, size: 16) }
        }
    }
}

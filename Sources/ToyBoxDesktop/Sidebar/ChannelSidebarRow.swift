import ChannelKit
import SwiftUI
import ToyBoxUI

/// A Mail-style source-list row: icon, name and last activity, then folder or purpose with the
/// working agents and attention trailing. See the spec's Sidebar section for the metrics.
struct ChannelSidebarRow: View {
    let channel: Channel
    let agents: [ChannelAgent]
    let working: [ChannelAgent]
    let attention: ChannelAttention?
    /// Nil when the channel has no directory.
    let folder: ChannelFolderAvailability?
    var openFolder: () -> Void
    var onTap: () -> Void

    var body: some View {
        // The content is its own view so its environment reads, such as the selection's
        // prominence, invalidate it. Reads inside this closure wouldn't.
        TimelineView(.everyMinute) { context in
            ChannelSidebarRowContent(row: self, now: context.date)
        }
    }

    /// Face counts line 2 tries, most first. A smaller count is offered only while its `+N` stands
    /// for at least two agents, because `+1` is wider than the face it replaces.
    static func faceLimits(working count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let full = min(count, 3)
        return [full] + (1..<full).reversed().filter { count - $0 >= 2 }
    }

}

private struct ChannelSidebarRowContent: View {
    let row: ChannelSidebarRow
    let now: Date
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.channelTextScale) private var scale
    @Environment(\.backgroundProminence) private var prominence
    @ViewState private var folderFrame: CGRect = .null

    private static let space = "ChannelSidebarRow"

    private var channel: Channel { row.channel }
    private var working: [ChannelAgent] { row.working }
    private var attention: ChannelAttention? { row.attention }
    private var folder: ChannelFolderAvailability? { row.folder }
    /// The key window's accent selection, where every custom color yields to white.
    private var emphasized: Bool { prominence == .increased }
    private var updatedAt: Date? { ChannelDates.date(channel.updatedAt) }

    var body: some View {
        content
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(channel.name)
            .accessibilityValue(help)
            .accessibilityActions {
                if folder == .openable { Button("Open Folder in Finder", action: row.openFolder) }
            }
            .contentShape(Rectangle())
            .coordinateSpace(.named(Self.space))
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { value in
                if !folderFrame.contains(value.location) { row.onTap() }
            })
    }

    private var content: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(channel.name)
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let updatedAt {
                        Text(ChannelActivityTime.label(for: updatedAt, now: now))
                            .font(.system(size: 11 * scale)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
                secondLine
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(minHeight: 52 * scale)
    }

    /// The stack gives up faces before the folder or purpose gives up letters. Only the candidate
    /// that fits is placed, so only its folder token reports a frame.
    private var secondLine: some View {
        let limits = ChannelSidebarRow.faceLimits(working: working.count)
        return ViewThatFits(in: .horizontal) {
            ForEach(limits, id: \.self) { limit in
                secondLine(faces: limit, detailYields: false)
            }
            secondLine(faces: limits.last ?? 0, detailYields: true)
        }
        .frame(height: 18 * scale)
    }

    private func secondLine(faces: Int, detailYields: Bool) -> some View {
        HStack(spacing: 0) {
            detail(yields: detailYields)
            // The folder token's own 6-point trailing padding makes 12 before the stack.
            Spacer(minLength: showsFolder ? 6 : 12)
            if faces > 0 { AgentAvatarStack(agents: working, size: 16, limit: faces).fixedSize() }
            if attention != nil { attentionIndicator.frame(width: 16, height: 16).padding(.leading, 6) }
        }
    }

    private var icon: some View {
        ChannelMark(emphasized: emphasized)
    }

    private var showsFolder: Bool {
        channel.directory?.isEmpty == false && folder != nil
    }

    /// Until it yields, a folder keeps its whole name and a purpose asks for about ten characters.
    @ViewBuilder private func detail(yields: Bool) -> some View {
        if let directory = channel.directory, !directory.isEmpty, let folder {
            ChannelFolderToken(path: directory, availability: folder, emphasized: emphasized, open: row.openFolder)
                .fixedSize(horizontal: !yields, vertical: false)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { folderFrame = $0 }
                .padding(.leading, -6)
                .layoutPriority(1)
        } else if let purpose = channelPurposePreview(channel.purpose) {
            Text(purpose).font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, idealWidth: yields ? nil : 60, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
    }

    @ViewBuilder private var attentionIndicator: some View {
        switch attention {
        case .waiting:
            Image(systemName: ChannelAttentionStyle.symbol(for: .waiting)).font(.system(size: 13))
                .foregroundStyle(emphasized ? .white : ChannelAttentionStyle.color(for: .waiting, in: colorScheme))
        case .finished:
            Image(systemName: ChannelAttentionStyle.symbol(for: .finished)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(emphasized ? .white : ChannelAttentionStyle.color(for: .finished, in: colorScheme))
        case .unread:
            Circle().fill(emphasized ? .white : ChannelAttentionStyle.color(for: .unread, in: colorScheme))
                .frame(width: 7, height: 7)
        case nil:
            EmptyView()
        }
    }

    private var help: String {
        var parts: [String] = []
        if let updatedAt { parts.append(ChannelActivityTime.accessibilityLabel(for: updatedAt, now: now)) }
        if let directory = channel.directory, !directory.isEmpty {
            let name = ChannelFolderToken.name(of: directory)
            switch folder {
            case .remote: parts.append("Folder \(name), not on this Mac")
            case .missing: parts.append("Folder \(name), missing")
            default: parts.append("Folder \(name)")
            }
        } else if let purpose = channelPurposePreview(channel.purpose) {
            parts.append(purpose)
        }
        switch attention {
        case .waiting: parts.append("Waiting for your response")
        case .finished: parts.append("All tasks completed")
        case .unread: parts.append("Unread messages")
        case nil: break
        }
        if !working.isEmpty {
            parts.append(working.map(\.name).formatted(.list(type: .and)) + " working")
        }
        parts.append("Team: " + row.agents.map(\.name).formatted(.list(type: .and)))
        return parts.joined(separator: ". ")
    }
}

/// The folder on a row's second line. It's a button only when the folder is on this Mac.
struct ChannelFolderToken: View {
    let path: String
    let availability: ChannelFolderAvailability
    let emphasized: Bool
    let open: () -> Void
    @Environment(\.channelTextScale) private var scale

    static func name(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    var body: some View {
        switch availability {
        case .openable:
            Button(action: open) { label(symbol: "folder").foregroundStyle(.secondary) }
                .buttonStyle(TokenCapsuleButtonStyle(emphasized: emphasized))
                .help("Open \(Self.name(of: path)) in Finder\n\((path as NSString).abbreviatingWithTildeInPath)")
        case .remote(let host):
            label(symbol: "folder").foregroundStyle(.secondary)
                .help("On \(host): \(path). Folders open only when the server runs on this Mac.")
        case .missing:
            label(symbol: "questionmark.folder").foregroundStyle(.secondary)
                .help("This folder no longer exists: \(path)")
        }
    }

    private func label(symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10 * scale, weight: .medium))
            Text(Self.name(of: path)).font(.system(size: 11 * scale))
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .frame(height: 18 * scale)
        .contentShape(Capsule())
    }
}

/// The folder token's hover and press capsule, also worn by the sidebar's server line.
struct TokenCapsuleButtonStyle: ButtonStyle {
    let emphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        TokenCapsuleButton(configuration: configuration, emphasized: emphasized)
    }
}

private struct TokenCapsuleButton: View {
    let configuration: ButtonStyleConfiguration
    let emphasized: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var isHovered = false

    var body: some View {
        configuration.label
            .background {
                if isHovered || configuration.isPressed { Capsule().fill(fill) }
            }
            .onHover { isHovered = $0 }
    }

    private var fill: AnyShapeStyle {
        let pressed = configuration.isPressed ? 0.05 : 0
        if emphasized { return AnyShapeStyle(Color.white.opacity(0.2 + pressed)) }
        return AnyShapeStyle(HierarchicalShapeStyle.primary.opacity((colorScheme == .dark ? 0.12 : 0.08) + pressed))
    }
}

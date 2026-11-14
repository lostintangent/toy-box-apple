import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// A Mail-style source-list row: the channel's avatar, name and last activity, then folder or
/// purpose with the working agents and attention trailing. See the spec's Sidebar section for the
/// metrics.
struct ChannelSidebarRow: View {
    let channel: Channel
    let agents: [ChannelAgent]
    let working: [ChannelAgent]
    let attention: Channel.Attention?
    /// Nil when the channel has no directory.
    let folder: ChannelFolderAvailability?
    /// The channel's server, which an image avatar loads from.
    var api: ChannelAPI? = nil
    var openFolder: () -> Void
    var onTap: () -> Void

    var body: some View {
        // The content is its own view so its environment reads, such as the selection's
        // prominence, invalidate it. Reads inside this closure wouldn't.
        TimelineView(.everyMinute) { context in
            ChannelSidebarRowContent(row: self, now: context.date)
        }
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
    private var attention: Channel.Attention? { row.attention }
    private var folder: ChannelFolderAvailability? { row.folder }
    /// The key window's accent selection, where every custom color yields to white.
    private var emphasized: Bool { prominence == .increased }
    private var updatedAt: Date? { try? Date(channel.updatedAt, strategy: .iso8601) }

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
        let limits = AgentAvatarStack.faceLimits(for: working.count)
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

    /// The avatar keeps its own colors on the accent selection, like an app icon in System Settings.
    private var icon: some View {
        ChannelMark(channel.avatar, api: row.api)
    }

    private var showsFolder: Bool {
        channel.directory?.isEmpty == false && folder != nil
    }

    /// Until it yields, a folder keeps its whole name and a purpose asks for about ten characters.
    @ViewBuilder private func detail(yields: Bool) -> some View {
        if let directory = channel.directory, !directory.isEmpty, let folder {
            ChannelFolderToken(path: directory, availability: folder, open: row.openFolder)
                .fixedSize(horizontal: !yields, vertical: false)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { folderFrame = $0 }
                .padding(.leading, -6)
                .layoutPriority(1)
        } else if let purpose = channel.purposePreview {
            Text(purpose).font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, idealWidth: yields ? nil : 60, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
    }

    @ViewBuilder private var attentionIndicator: some View {
        switch attention {
        case .waiting:
            Image(systemName: Channel.Attention.waiting.symbol).font(.system(size: 13))
                .foregroundStyle(emphasized ? .white : Channel.Attention.waiting.color(in: colorScheme))
        case .finished:
            Image(systemName: Channel.Attention.finished.symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(emphasized ? .white : Channel.Attention.finished.color(in: colorScheme))
        case .unread:
            Circle().fill(emphasized ? .white : Channel.Attention.unread.color(in: colorScheme))
                .frame(width: 7, height: 7)
        case nil:
            EmptyView()
        }
    }

    private var help: String {
        var parts: [String] = []
        if let updatedAt { parts.append(ChannelActivityTime.accessibilityLabel(for: updatedAt, now: now)) }
        if let directory = channel.directory, !directory.isEmpty {
            let name = ChannelFolderName.name(of: directory)
            switch folder {
            case .remote: parts.append("Folder \(name), not on this Mac")
            case .missing: parts.append("Folder \(name), missing")
            default: parts.append("Folder \(name)")
            }
        } else if let purpose = channel.purposePreview {
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
    let open: () -> Void
    @Environment(\.channelTextScale) private var scale

    var body: some View {
        switch availability {
        case .openable:
            Button(action: open) { token(symbol: "folder") }
                .buttonStyle(HoverFillButtonStyle(shape: Capsule()))
                .help("Open \(ChannelFolderName.name(of: path)) in Finder\n\((path as NSString).abbreviatingWithTildeInPath)")
        case .remote(let host):
            token(symbol: "folder").foregroundStyle(.secondary)
                .help("On \(host): \(path). Folders open only when the server runs on this Mac.")
        case .missing:
            token(symbol: "questionmark.folder").foregroundStyle(.secondary)
                .help("This folder no longer exists: \(path)")
        }
    }

    private func token(symbol: String) -> some View {
        Label(path: path, symbol: symbol)
            .padding(.horizontal, 6)
            .frame(height: 18 * scale)
            .contentShape(Capsule())
    }

    /// The folder's symbol and name, which Quick Send's chooser shows on their own.
    struct Label: View {
        let path: String
        var symbol = "folder"
        @Environment(\.channelTextScale) private var scale

        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10 * scale, weight: .medium))
                Text(ChannelFolderName.name(of: path)).font(.system(size: 11 * scale))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

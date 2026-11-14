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
    /// The selected row keeps the list's own highlight, so it never lights.
    var isSelected = false
    /// The request the row answers from its popover, while it waits and isn't selected.
    var request: ChannelWaitingRequest? = nil
    var answers: SidebarAnswers? = nil
    /// The done check the avatar wears once the row's reply sends.
    var check: CardChecks.Check? = nil
    /// The recorder, on the row it holds and on the card's copy of it, which never lights.
    var talk: TalkRecorder? = nil
    /// Starts a note to the Lead from the hover mic, while the row offers one.
    var startTalk: (() -> Void)? = nil
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
    @Environment(\.windowSnapshot) private var snapshot
    @ViewState private var folderFrame: CGRect = .null
    @ViewState private var bubbleFrame: CGRect = .null
    @ViewState private var micFrame: CGRect = .null
    @ViewState private var isHovered = false
    @ViewState private var isPopoverHovered = false
    @GestureState private var isPressed = false

    private static let space = "ChannelSidebarRow"
    /// How long the pointer rests on a waiting row before its popover opens, and how long it may
    /// spend crossing between the row and the popover before leaving closes it.
    private static let rest = Duration.seconds(0.5)
    private static let crossing = Duration.seconds(0.3)

    private var channel: Channel { row.channel }
    private var working: [ChannelAgent] { row.working }
    private var attention: Channel.Attention? { row.attention }
    private var folder: ChannelFolderAvailability? { row.folder }
    /// The key window's accent selection, where every custom color yields to white.
    private var emphasized: Bool { prominence == .increased }
    private var updatedAt: Date? { try? Date(channel.updatedAt, strategy: .iso8601) }

    private var isOpen: Bool { row.answers?.isOpen == true && row.request != nil }
    /// The pointer's over the row, which the recorder's row ignores.
    private var hovers: Bool { (isHovered || snapshot?.requestedState == "hover-all") && row.talk == nil }
    private var isLit: Bool {
        !row.isSelected && (hovers || isPressed || isOpen)
    }
    private var showsMic: Bool { hovers && row.startTalk != nil }
    /// Leaving the row and its unpinned popover closes it, once the pointer isn't crossing between them.
    private var isLeaving: Bool {
        isOpen && !isHovered && !isPopoverHovered && row.answers?.isPinned != true
    }

    var body: some View {
        content
            .background { hoverFill }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(channel.name)
            .talkValue(row.talk, details: help)
            .accessibilityActions {
                if let startTalk = row.startTalk { Button("Talk to Lead", action: startTalk) }
                if row.request != nil {
                    Button("Answer Request") {
                        row.answers?.isOpen = true
                        row.answers?.isPinned = true
                    }
                }
                if folder == .openable { Button("Open Folder in Finder", action: row.openFolder) }
            }
            .contentShape(Rectangle())
            .coordinateSpace(.named(Self.space))
            .onHover { isHovered = $0 }
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { value in
                if ![folderFrame, bubbleFrame, micFrame].contains(where: { $0.contains(value.location) }) { row.onTap() }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isPressed) { _, pressed, _ in pressed = true })
            .popover(item: Binding(get: { isOpen ? row.request : nil }, set: { if $0 == nil { row.answers?.isOpen = false } }),
                     arrowEdge: .trailing) { entry in
                if let answers = row.answers {
                    SidebarRequestPopover(entry: entry, answers: answers, isHovered: $isPopoverHovered)
                }
            }
            .task(id: hovers) {
                guard hovers, row.request != nil, (try? await Task.sleep(for: Self.rest)) != nil else { return }
                row.answers?.isOpen = true
            }
            .task(id: isLeaving) {
                guard isLeaving, (try? await Task.sleep(for: Self.crossing)) != nil else { return }
                row.answers?.isOpen = false
            }
            // A request answered, replaced or selected closes its popover.
            .onChange(of: row.request?.id) { if row.answers?.isOpen == true { row.answers?.isOpen = false } }
    }

    /// The hover fill in the row's own shape, or orange on a waiting row, which stays lit while its
    /// popover is open.
    private var hoverFill: some View {
        let dark = colorScheme == .dark
        let pressed = isPressed ? 0.05 : 0
        let fill = attention == .waiting
            ? Channel.Attention.waiting.color(in: colorScheme).opacity((dark ? 0.2 : 0.14) + pressed)
            : Color.primary.opacity((dark ? 0.12 : 0.08) + pressed)
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
            // Out to the list's row inset, where its own selection draws.
            .padding(.horizontal, -6)
            .opacity(isLit ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isLit)
            .animation(.easeOut(duration: 0.12), value: isPressed)
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
                    time
                }
                secondLine.talkLine(row.talk)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(minHeight: 52 * scale)
    }

    /// The last activity, which the hover mic replaces and the recorder's counter takes over. The
    /// counter takes the time's font.
    private var time: some View {
        Text(updatedAt.map { ChannelActivityTime.label(for: $0, now: now) } ?? "")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
            .opacity(showsMic ? 0 : 1)
            .overlay(alignment: .trailing) {
                if showsMic, let startTalk = row.startTalk {
                    Button(action: startTalk) {
                        Image(systemName: "mic.fill").font(.system(size: 10 * scale, weight: .medium))
                            .padding(.horizontal, 6)
                            .frame(height: 18 * scale)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(HoverFillButtonStyle(shape: Capsule()))
                    .help("Talk to Lead")
                    // The mic ends on the time's trailing edge, like the folder's name starts on the line's.
                    .padding(.trailing, -6)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { micFrame = $0 }
                    .onDisappear { micFrame = .null }
                }
            }
            .talkTime(row.talk)
            .font(.system(size: 11 * scale))
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
            if attention != nil {
                attentionIndicator.frame(width: 16, height: 16).padding(.leading, 6).talkFades(row.talk)
            }
        }
    }

    /// The avatar keeps its own colors on the accent selection, like an app icon in System Settings.
    /// It wears the done check once the row's reply sends, and the recorder's mic while it records.
    private var icon: some View {
        ChannelMark(channel.avatar, api: row.api)
            .cardMark(row.check == .sent ? .check : .channel)
            .talkMark(row.talk)
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
            let bubble = Image(systemName: Channel.Attention.waiting.symbol).font(.system(size: 13))
                .foregroundStyle(emphasized ? .white : Channel.Attention.waiting.color(in: colorScheme))
            if row.request != nil {
                Button { row.answers?.isOpen = true } label: { bubble.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { bubbleFrame = $0 }
                    .onDisappear { bubbleFrame = .null }
            } else {
                bubble
            }
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
            let name = Channel.folderName(of: directory)
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
                .help("Open \(Channel.folderName(of: path)) in Finder\n\((path as NSString).abbreviatingWithTildeInPath)")
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
                Text(Channel.folderName(of: path)).font(.system(size: 11 * scale))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

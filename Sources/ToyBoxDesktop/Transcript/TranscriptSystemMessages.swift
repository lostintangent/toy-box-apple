import ChannelClient
import ChannelKit
import SwiftUI

/// Channel events sit in the neutral center of the conversation, as in Messages: one centered
/// sentence led by its inline symbol, with values in primary ink and links in native link ink.
struct TranscriptSystemMessages: View {
    let messages: [ChannelMessage]
    let state: ChannelState
    let api: ChannelAPI
    @Environment(AppModel.self) private var app
    @Environment(ArtifactOpener.self) private var artifactOpener
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme

    private var contents: [ChannelSystemContent] { messages.compactMap(\.system) }
    private var first: ChannelSystemContent? { contents.first }

    var body: some View {
        content
            .font(.system(size: 11 * textScale))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480 * textScale)
            .frame(maxWidth: .infinity, minHeight: 18 * textScale)
            .help(help)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var content: some View {
        switch first?.type {
        case "tasks_completed": sentence("All tasks completed")
        case "member_joined", "member_left": sentence(membershipLabel.text, spoken: membershipLabel.spoken)
        case "channel_renamed":
            event("Channel renamed", value: first?.name).lineLimit(3)
        case "channel_purpose_changed":
            event(first?.purpose == nil ? "Purpose cleared" : "Purpose updated", value: first?.purpose).lineLimit(3)
        case "channel_directory_changed":
            if let directory = first?.directory {
                valueLine("Working directory changed") {
                    Text(directory).foregroundStyle(.primary).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                }
            } else { sentence("Working directory cleared") }
        case "preview_changed":
            if let preview = first?.preview ?? first?.previewUrl.map({ ChannelPreview(kind: "url", url: $0) }) {
                if preview.kind == "url" {
                    if let address = preview.url, let url = api.resourceURL(address) {
                        valueLine("Preview updated") {
                            Link(destination: url) { TranscriptSystemLinkLabel(title: address) }
                                .transcriptSystemLink()
                                .lineLimit(1).truncationMode(.middle)
                        }
                    } else {
                        sentence("Preview link unavailable").help(preview.url ?? "Missing URL")
                    }
                } else if preview.kind == "screen" {
                    if let url = app.channelURL(channelID: state.channel.id) {
                        valueLine("Preview updated") {
                            Link(destination: url) { TranscriptSystemLinkLabel(title: "Open screen in Toy Box") }
                                .transcriptSystemLink()
                                .lineLimit(1)
                        }
                    } else { sentence("Preview updated") }
                } else {
                    sentence("Preview updated").help("Unsupported preview kind: \(preview.kind)")
                }
            } else { sentence("Preview cleared") }
        case "artifact_shared":
            TranscriptArtifactShares(icon: icon, actorName: actorName, messages: messages,
                                     historyStart: state.messages.first?.sequence ?? 0,
                                     onOpen: artifactOpener.open)
        case "routine_scheduled", "routine_edited", "routine_deleted":
            event(routineLabel, value: first?.routine?.title ?? "Routine").lineLimit(3)
        default:
            if let description = first?.unknownFields?["description"]?.string {
                sentence(Text("Channel updated\n\(description)"), spoken: "Channel updated. \(description)")
                    .lineLimit(4)
            } else { sentence("Channel updated") }
        }
    }

    private var icon: Text {
        Text(Image(systemName: Self.symbol(for: first?.type)))
            .foregroundStyle(Self.symbolColor(for: first?.type, in: colorScheme))
    }

    /// The sentence led by its symbol. VoiceOver reads only the words, since the symbol would
    /// otherwise speak as an object replacement character. Selectable text reports its raw string
    /// and ignores a label, so the words replace its accessibility element instead.
    private func sentence(_ text: Text, spoken: String) -> some View {
        Text("\(icon)  \(text)").accessibilityRepresentation { Text(spoken) }
    }

    private func sentence(_ phrase: String) -> some View { sentence(Text(phrase), spoken: phrase) }

    private func event(_ name: String, value: String?) -> some View {
        sentence(eventLabel(name, value: value), spoken: value.map { "\(name) \(transcriptSystemValue($0))" } ?? name)
    }

    /// A phrase followed by one value that truncates in place, so the sentence keeps one line.
    private func valueLine<Value: View>(_ phrase: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            sentence(phrase).lineLimit(1).layoutPriority(1)
            value()
        }
    }

    /// The symbol that leads an event's sentence, which a catch-up line from that event shares.
    static func symbol(for type: String?) -> String {
        switch type {
        case "tasks_completed": "checkmark.circle.fill"
        case "member_joined": "person.badge.plus"
        case "member_left": "person.badge.minus"
        case "channel_renamed", "channel_purpose_changed": "pencil"
        case "channel_directory_changed": "folder"
        case "preview_changed": "play.rectangle"
        case "artifact_shared": "doc.badge.arrow.up"
        case "routine_scheduled", "routine_edited", "routine_deleted": "calendar.badge.clock"
        default: "info.circle"
        }
    }

    static func symbolColor(for type: String?, in colorScheme: ColorScheme) -> Color {
        type == "tasks_completed" ? ChannelTaskColors.changes(in: colorScheme).added : .secondary
    }

    private func eventLabel(_ event: String, value: String?) -> Text {
        guard let value else { return Text(event) }
        return Text("\(Text(event)) \(Text(transcriptSystemValue(value)).foregroundStyle(.primary).fontWeight(.medium))")
    }

    private var membershipLabel: (text: Text, spoken: String) {
        let names = contents.compactMap { $0.member?.name }
        let action = first?.type == "member_joined" ? "joined" : "left"
        guard let name = names.first else { return (Text("Channel membership changed"), "Channel membership changed") }
        let identities = names.count == 1 ? name
            : "\(name) and \(names.count - 1) \(names.count == 2 ? "other" : "others")"
        return (Text("\(Text(identities).foregroundStyle(.primary).fontWeight(.medium)) \(action) the channel"),
                "\(identities) \(action) the channel")
    }

    private var actorName: String {
        first?.actor?.type == "user" ? "You"
            : channelAgentIdentity(state.agents, id: first?.actor?.agentId ?? "").name
    }

    private var routineLabel: String {
        switch first?.type {
        case "routine_scheduled": "New routine scheduled"
        case "routine_edited": "Routine edited"
        default: "Routine deleted"
        }
    }

    private var help: String {
        let detail: String
        switch first?.type {
        case "member_joined", "member_left": detail = contents.compactMap { $0.member?.name }.joined(separator: ", ")
        case "channel_purpose_changed": detail = first?.purpose ?? "Purpose cleared"
        case "channel_directory_changed": detail = first?.directory ?? "Working directory cleared"
        case "channel_renamed": detail = first?.name ?? ""
        case "routine_scheduled", "routine_edited", "routine_deleted":
            detail = [first?.routine?.title, first?.routine?.schedule, first?.routine?.prompt]
                .compactMap { $0 }.joined(separator: "\n")
        default: detail = first?.unknownFields?["description"]?.string ?? ""
        }
        let timestamp = messages.first.flatMap { ChannelDates.date($0.timestamp) }?
            .formatted(date: .complete, time: .shortened) ?? ""
        return [detail, timestamp].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Collapses whitespace and keeps at most 120 characters, as the pane does for changed values.
func transcriptSystemValue(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.count <= 120 ? line : "\(line.prefix(117))..."
}

struct TranscriptArtifactShares: View {
    var icon: Text?
    let actorName: String
    let messages: [ChannelMessage]
    let historyStart: Int
    var onOpen: (ChannelArtifact) -> Void
    @Environment(\.channelTextScale) private var textScale

    private var shares: [(message: ChannelMessage, artifact: ChannelArtifact)] {
        messages.compactMap { message in message.system?.artifact.map { (message, $0) } }
    }

    var body: some View {
        let shares = shares
        TranscriptCenteredFlow(spacing: 3 * textScale, lineSpacing: 2 * textScale) {
            actorLabel
            ForEach(Array(shares.enumerated()), id: \.element.message.id) { index, share in
                let joiners = transcriptListJoiners(index: index, count: shares.count)
                if let before = joiners.before { Text(before) }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Button { onOpen(share.artifact) } label: {
                        TranscriptSystemLinkLabel(title: share.artifact.title)
                    }
                    .transcriptSystemLink()
                    .help(share.artifact.file.path)
                    if let after = joiners.after { Text(after) }
                }
                .transcriptMessageFrame(id: share.message.id, sequence: share.message.sequence,
                                        historyStart: historyStart)
                .id(share.message.id)
            }
        }
    }

    @ViewBuilder private var actorLabel: some View {
        let actor = Text("\(Text(actorName).foregroundStyle(.primary).fontWeight(.medium)) shared")
        if let icon {
            Text("\(icon)  \(actor)").accessibilityRepresentation { Text("\(actorName) shared") }
        } else {
            actor
        }
    }
}

/// The pane's list joiners: "A and B", and "A, B, and C" from three items on.
func transcriptListJoiners(index: Int, count: Int) -> (before: String?, after: String?) {
    (index > 0 && index == count - 1 ? "and" : nil, count > 2 && index < count - 1 ? "," : nil)
}

/// Wraps inline pieces, such as phrases and individually actionable links, into lines that are
/// each centered and share a first-text baseline. A piece wider than a line wraps within it.
struct TranscriptCenteredFlow: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 2

    private struct Item { var index: Int; var size: CGSize; var baseline: CGFloat }
    private struct Line { var items: [Item] = []; var width: CGFloat = 0; var ascent: CGFloat = 0; var descent: CGFloat = 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.ascent + $1.descent }
            + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.midX - line.width / 2
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + line.ascent - item.baseline),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.ascent + line.descent + lineSpacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var proposal = ProposedViewSize.unspecified
            var size = subviews[index].sizeThatFits(proposal)
            if size.width > width {
                proposal = ProposedViewSize(width: width, height: nil)
                size = subviews[index].sizeThatFits(proposal)
            }
            if !line.items.isEmpty && line.width + spacing + size.width > width {
                lines.append(line)
                line = Line()
            }
            let baseline = subviews[index].dimensions(in: proposal)[VerticalAlignment.firstTextBaseline]
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.ascent = max(line.ascent, baseline)
            line.descent = max(line.descent, size.height - baseline)
            line.items.append(Item(index: index, size: size, baseline: baseline))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}

/// A compact link label whose padding grows its button's click and hover target to about
/// 28 points tall. `transcriptSystemLink()` gives that padding back so the line keeps its layout.
struct TranscriptSystemLinkLabel: View {
    let title: String
    @ViewState private var isHovered = false

    static var ink: Color { Color(nsColor: .linkColor) }
    static let outset: CGFloat = 8

    var body: some View {
        Text(title)
            .foregroundStyle(Self.ink)
            .fontWeight(.medium)
            .underline(isHovered)
            .padding(.vertical, Self.outset)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func transcriptSystemLink() -> some View {
        buttonStyle(.link)
            .padding(.vertical, -TranscriptSystemLinkLabel.outset)
            .padding(.horizontal, -2)
    }
}

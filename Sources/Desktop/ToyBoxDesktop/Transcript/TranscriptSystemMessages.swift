import ToyBoxClient
import ToyBoxKit
import SwiftUI
import ToyBoxUI

/// Channel events sit in the neutral center of the conversation, as in Messages: one centered
/// sentence led by its inline symbol, with values in primary ink and links in native link ink.
struct TranscriptSystemMessages: View {
    let messages: [ChannelMessage]
    let historyStart: Int
    let agents: [ChannelAgent]
    let api: ChannelAPI
    var findHighlights: [Int: TranscriptFindHighlight] = [:]
    var expandsMembership = false
    @Environment(ArtifactOpener.self) private var artifactOpener
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    private var contents: [ChannelSystemContent] { messages.compactMap(\.system) }
    private var first: ChannelSystemContent? { contents.first }
    private var findHighlight: TranscriptFindHighlight? {
        messages.compactMap { findHighlights[$0.sequence] }.first(where: \.isCurrent)
            ?? messages.compactMap { findHighlights[$0.sequence] }.first
    }

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
        let phrase = ChannelSystemContent.phrase(for: first)
        switch first?.type {
        case "tasks_completed": sentence(phrase)
        case "member_joined", "member_left":
            if messages.count > 1 && expandsMembership {
                VStack(spacing: 4) {
                    ForEach(messages) { message in
                        TranscriptSystemMessages(messages: [message], historyStart: historyStart,
                                                 agents: agents, api: api, findHighlights: findHighlights)
                            .transcriptMessageFrame(id: message.id, sequence: message.sequence,
                                                    historyStart: historyStart)
                            .id(message.id)
                    }
                }
            } else { sentence(membershipLabel.text, spoken: membershipLabel.spoken) }
        case "channel_renamed":
            event(phrase, value: first?.name).lineLimit(3)
        case "channel_avatar_changed":
            HStack(spacing: 4 * textScale) {
                sentence(phrase)
                // As tall as a line of 11-point system text, which measures 13 points.
                if let avatar = first?.avatar {
                    ChannelMark(avatar, api: api, size: 13 * textScale).accessibilityHidden(true)
                }
            }
        case "channel_purpose_changed":
            event(phrase, value: first?.purpose).lineLimit(3)
        case "channel_directory_changed":
            if let directory = first?.directory {
                valueLine(phrase, findText: "\(phrase) \(directory)") {
                    findText(directory, in: "\(phrase) \(directory)", offset: "\(phrase) ".utf16.count)
                        .foregroundStyle(.primary).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                }
            } else { sentence(phrase) }
        case "preview_changed":
            if let preview = first?.preview {
                if preview.kind == "url" {
                    if let address = preview.url, let url = api.resourceURL(address) {
                        valueLine(phrase, findText: "\(phrase) \(address)") {
                            Link(destination: url) {
                                TranscriptSystemLinkLabel(title: address, findHighlight: findHighlight,
                                                          findText: "\(phrase) \(address)",
                                                          findOffset: "\(phrase) ".utf16.count)
                            }
                                .transcriptSystemLink()
                                .lineLimit(1).truncationMode(.middle)
                        }
                    } else {
                        sentence(ChannelSystemContent.unavailablePreview).help(preview.url ?? "Missing URL")
                    }
                } else if preview.kind == "screen" {
                    if let screenID = preview.screenId {
                        let screen = ChannelSystemContent.screenPreview
                        valueLine(phrase, findText: "\(phrase) \(screen)") {
                            Button { openWindow(id: "screens", value: ScreenWindowValue(serverURL: api.baseURL.absoluteString, screenID: screenID)) } label: {
                                TranscriptSystemLinkLabel(title: screen, findHighlight: findHighlight,
                                                          findText: "\(phrase) \(screen)",
                                                          findOffset: "\(phrase) ".utf16.count)
                            }
                                .transcriptSystemLink()
                                .lineLimit(1)
                        }
                    } else { sentence(phrase) }
                } else {
                    sentence(phrase).help("Unsupported preview kind: \(preview.kind)")
                }
            } else { sentence(phrase) }
        case "artifact_shared", "artifact_removed":
            if let group = ChannelArtifactGroup(messages, agents: agents) {
                TranscriptArtifactGroupLine(icon: icon, group: group, historyStart: historyStart,
                                            findHighlights: findHighlights, onOpen: artifactOpener.open)
            } else { sentence(phrase) }
        case "routine_scheduled", "routine_edited", "routine_deleted":
            event(phrase, value: first?.routine?.title ?? "Routine").lineLimit(3)
        default:
            if let description = first?.unknownFields?["description"]?.string {
                sentence(findText("\(phrase)\n\(description)"), spoken: "\(phrase). \(description)")
                    .lineLimit(4)
            } else { sentence(phrase) }
        }
    }

    private var icon: Text {
        Text(Image(systemName: ChannelSystemEventStyle.symbol(for: first?.type)))
            .foregroundStyle(ChannelSystemEventStyle.symbolColor(for: first?.type, in: colorScheme))
    }

    /// The sentence led by its symbol. VoiceOver reads only the words, since the symbol would
    /// otherwise speak as an object replacement character. Selectable text reports its raw string
    /// and ignores a label, so the words replace its accessibility element instead.
    private func sentence(_ text: Text, spoken: String) -> some View {
        Text("\(icon)  \(text)").accessibilityRepresentation { Text(spoken) }
    }

    private func sentence(_ phrase: String, in text: String? = nil) -> some View {
        sentence(findText(phrase, in: text), spoken: phrase)
    }

    private func findText(_ value: String, in text: String? = nil, offset: Int = 0) -> Text {
        let ranges = text.map { TranscriptFindPattern(findHighlight?.query ?? "").ranges(in: $0) }
        return Text(findHighlight?.applying(to: AttributedString(value), ranges: ranges, offset: offset)
                    ?? AttributedString(value))
    }

    private func event(_ name: String, value: String?) -> some View {
        sentence(eventLabel(name, value: value), spoken: value.map { "\(name) \(ChannelSystemContent.value($0))" } ?? name)
    }

    /// A phrase followed by one value that truncates in place, so the sentence keeps one line.
    private func valueLine<Value: View>(_ phrase: String, findText: String? = nil,
                                       @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            sentence(phrase, in: findText).lineLimit(1).layoutPriority(1)
            value()
        }
    }

    private func eventLabel(_ event: String, value: String?) -> Text {
        guard let value else { return findText(event) }
        var detail = AttributedString(ChannelSystemContent.value(value))
        detail.foregroundColor = .primary
        detail.font = .system(size: 11 * textScale, weight: .medium)
        let label = AttributedString(event + " ") + detail
        return Text(findHighlight?.applying(to: label) ?? label)
    }

    private var membershipLabel: (text: Text, spoken: String) {
        guard let membership = ChannelSystemContent.membership(contents) else {
            let phrase = ChannelSystemContent.phrase(for: first)
            return (Text(phrase), phrase)
        }
        var styledNames = AttributedString(membership.names)
        styledNames.foregroundColor = .primary
        styledNames.font = .system(size: 11 * textScale, weight: .medium)
        let label = styledNames + AttributedString(" \(membership.action)")
        return (Text(findHighlight?.applying(to: label) ?? label), "\(membership.names) \(membership.action)")
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
        let timestamp = messages.first.flatMap { try? Date($0.timestamp, strategy: .iso8601) }?
            .formatted(date: .complete, time: .shortened) ?? ""
        return [detail, timestamp].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// One artifact group's line: the actor and verb, then each title as a link. A removed title
/// still opens, since its file stays on disk.
struct TranscriptArtifactGroupLine: View {
    var icon: Text?
    let group: ChannelArtifactGroup
    let historyStart: Int
    var findHighlights: [Int: TranscriptFindHighlight] = [:]
    var onOpen: (ChannelArtifact) -> Void
    @Environment(\.channelTextScale) private var textScale

    var body: some View {
        TranscriptCenteredFlow(spacing: 3 * textScale, lineSpacing: 2 * textScale) {
            actorLabel
            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                let joiners = transcriptListJoiners(index: index, count: group.entries.count)
                if let before = joiners.before { Text(before) }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    title(entry, at: index)
                    if let after = joiners.after { Text(after) }
                }
                .transcriptMessageFrame(id: entry.messageID, sequence: entry.sequence, historyStart: historyStart)
                .id(entry.messageID)
            }
        }
    }

    private func title(_ entry: ChannelArtifactGroup.Entry, at index: Int) -> some View {
        Button { onOpen(entry.artifact) } label: {
            TranscriptSystemLinkLabel(title: entry.artifact.title, findHighlight: findHighlights[entry.sequence],
                                      findText: group.sentence, findOffset: group.titleOffset(at: index))
        }
        .transcriptSystemLink()
        .help(entry.artifact.file.path)
    }

    private var actorText: Text {
        var name = AttributedString(group.actor)
        name.foregroundColor = .primary
        name.font = .system(size: 11 * textScale, weight: .medium)
        let label = name + AttributedString(" \(group.verb.rawValue)")
        let match = group.entries.first { findHighlights[$0.sequence]?.isCurrent == true }
            ?? group.entries.first { findHighlights[$0.sequence] != nil }
        guard let highlight = match.flatMap({ findHighlights[$0.sequence] }) else { return Text(label) }
        let ranges = TranscriptFindPattern(highlight.query).ranges(in: group.sentence)
        return Text(highlight.applying(to: label, ranges: ranges))
    }

    @ViewBuilder private var actorLabel: some View {
        let actor = actorText
        if let icon {
            Text("\(icon)  \(actor)").accessibilityRepresentation { Text("\(group.actor) \(group.verb.rawValue)") }
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
    var findHighlight: TranscriptFindHighlight?
    var findText: String?
    var findOffset = 0
    @ViewState private var isHovered = false

    static var ink: Color { Color(nsColor: .linkColor) }
    static let outset: CGFloat = 8

    var body: some View {
        let ranges = findText.map { TranscriptFindPattern(findHighlight?.query ?? "").ranges(in: $0) }
        Text(findHighlight?.applying(to: AttributedString(title), ranges: ranges, offset: findOffset)
             ?? AttributedString(title))
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

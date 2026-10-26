import AppIntents
import ChannelKit
import SwiftUI
import ToyBoxUI

/// What Siri's Catch Me Up card shows. It travels inside its snippet intent, so the system can draw
/// the card again after the app relaunches without asking the server or the model.
struct CatchUpCard: Codable, Equatable, Sendable {
    struct Line: Codable, Equatable, Sendable {
        enum Slot: Codable, Equatable, Sendable {
            /// The pending request, which turns to Replied once you answer it.
            case request
            case agent(ChannelAgent)
            case event(String?)
            case info
        }

        var slot: Slot
        /// The author, before their own words. The model's lines name people themselves.
        var speaker: String?
        var text: String
        /// The agents `text` mentions as "@Name", drawn in their mention ink.
        var mentions: [ChannelAgent]?
    }

    /// A channel in the overview, with the sidebar's indicator.
    struct Row: Codable, Equatable, Sendable {
        var channelID: String
        var name: String
        var attention: String?
        var detail: String
    }

    struct Reply: Codable, Equatable, Sendable {
        /// The agent who asked, unless they've left.
        var recipient: String?
        var request: Int
    }

    /// Nil for the overview of every channel that needs you.
    var channelID: String?
    var title: String
    var subtitle: String?
    var isSummary = false
    var lines: [Line] = []
    var rows: [Row] = []
    var footnote: String?
    var reply: Reply?
    /// Drawn from replies seen when the card draws, never from the server's state at Catch Me Up.
    var isReplied = false

    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    init(channelID: String?, title: String, subtitle: String? = nil, isSummary: Bool = false,
         lines: [Line] = [], rows: [Row] = [], footnote: String? = nil, reply: Reply? = nil) {
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.isSummary = isSummary
        self.lines = lines
        self.rows = rows
        self.footnote = footnote
        self.reply = reply
    }

    /// The header's second line. A request's state leads it, so it follows your reply.
    var caption: String? {
        guard reply != nil, !isSummary else { return subtitle }
        let state = isReplied ? "Replied" : "Waiting for your reply"
        guard let subtitle else { return state }
        return "\(state) \u{00B7} \(subtitle.prefix(1).lowercased())\(subtitle.dropFirst())"
    }

    init?(encoded: String) {
        guard let card = try? JSONDecoder().decode(CatchUpCard.self, from: Data(encoded.utf8)) else { return nil }
        self = card
    }
}

/// Plain SwiftUI, because the system archives a snippet's view. Its buttons run intents, since a
/// closure in a snippet never runs.
struct CatchUpCardView: View {
    let card: CatchUpCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !card.lines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                        CatchUpCardLine(line: line, isReplied: card.isReplied)
                    }
                }
            }
            if !card.rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(card.rows, id: \.channelID) { CatchUpCardRow(row: $0) }
                }
            }
            if let footnote = card.footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if let channelID = card.channelID {
                actions(ChannelEntity(id: channelID, name: card.title))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            if let caption = card.caption {
                HStack(spacing: 5) {
                    if card.isSummary {
                        Image(systemName: "text.line.3.summary").accessibilityHidden(true)
                    }
                    Text(caption)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isAsking: Bool { card.reply != nil && !card.isReplied }

    @ViewBuilder private func actions(_ channel: ChannelEntity) -> some View {
        HStack(spacing: 8) {
            let reply = Button(intent: ReplyIntent(channel: channel, recipient: card.reply?.recipient,
                                                   request: card.reply?.request)) {
                Label(isAsking ? card.reply?.recipient.map { "Reply to \($0)" } ?? "Reply" : "Reply",
                      systemImage: "arrowshape.turn.up.left")
                    .frame(maxWidth: .infinity)
            }
            if isAsking {
                reply.buttonStyle(.borderedProminent)
            } else {
                reply.buttonStyle(.bordered)
            }
            Button(intent: OpenChannelIntent(target: channel)) {
                Label("Open", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }
}

private struct CatchUpCardLine: View {
    let line: CatchUpCard.Line
    let isReplied: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var isRequest: Bool {
        if case .request = line.slot { true } else { false }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            slot.frame(width: 16, height: 16)
            text
                .font(.system(size: 13, weight: isRequest ? .medium : .regular))
                .foregroundStyle(isRequest && isReplied ? .secondary : .primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var text: Text {
        let words = Text(inked)
        guard let speaker = line.speaker else { return words }
        return Text("\(Text("\(speaker):").fontWeight(.semibold)) \(words)")
    }

    /// Mentions in the transcript's mention ink and weight.
    private var inked: AttributedString {
        var text = AttributedString(line.text)
        let ink = TranscriptMentionInk(isDark: colorScheme == .dark, isContrastIncreased: contrast == .increased)
        let mentions = (line.mentions ?? []).map { ("@" + $0.name, Optional($0)) } + [("@everyone", nil)]
        for (token, agent) in mentions {
            for range in channelMentionRanges(of: token, in: line.text) {
                guard let lower = AttributedString.Index(range.lowerBound, within: text),
                      let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
                text[lower..<upper].font = .system(size: 13, weight: .semibold)
                text[lower..<upper].foregroundColor = ink.color(for: agent)
            }
        }
        return text
    }

    private var accessibilityText: String {
        let words = line.speaker.map { "\($0): \(line.text)" } ?? line.text
        guard isRequest else { return words }
        return (isReplied ? "Replied: " : "Needs your reply: ") + words
    }

    @ViewBuilder private var slot: some View {
        switch line.slot {
        case .request:
            Image(systemName: isReplied ? "checkmark" : "questionmark.bubble.fill")
                .font(.system(size: 13, weight: isReplied ? .semibold : .regular))
                .foregroundStyle(isReplied ? Color.secondary : Color.orange)
        case .agent(let agent):
            AgentAvatarView(agent: agent, size: 16)
        case .event(let type):
            Image(systemName: ChannelSystemEventStyle.symbol(for: type))
                .font(.system(size: 13))
                .foregroundStyle(ChannelSystemEventStyle.symbolColor(for: type, in: colorScheme))
        case .info:
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct CatchUpCardRow: View {
    let row: CatchUpCard.Row
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(intent: OpenChannelIntent(target: ChannelEntity(id: row.channelID, name: row.name,
                                                               attention: attention))) {
            HStack(spacing: 8) {
                indicator.frame(width: 16, height: 16)
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(row.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.name), \(row.detail)")
        .accessibilityHint("Opens the channel")
    }

    private var attention: ChannelAttention? { row.attention.flatMap(ChannelAttention.init(rawValue:)) }

    /// The sidebar's indicator.
    @ViewBuilder private var indicator: some View {
        switch attention {
        case .waiting:
            Image(systemName: "questionmark.bubble.fill").font(.system(size: 13))
                .foregroundStyle(Color.orange)
        case .finished:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChannelTaskColors.changes(in: colorScheme).added)
        case .unread:
            Circle().fill(.blue).frame(width: 7, height: 7)
        case nil:
            EmptyView()
        }
    }
}

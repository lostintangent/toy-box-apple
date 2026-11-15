import ToyBoxKit
import Foundation
import SwiftUI
import Testing
import ToyBoxUI

@Suite("Shared transcript message parts")
struct TranscriptMessageTests {
    @Test func runsSplitIntoItemsThatEachMarkTheirOwnSequence() {
        let lead = ChannelAgent(id: "lead", name: "Lead")
        let messages: [(Int, ChannelMessageSender)] = [(1, .user), (2, .agent("lead")), (3, .agent("lead")),
                                                       (4, .agent("ada"))]
        let rows = TranscriptRowBuilder().rows(messages.map {
            ChannelMessage(id: "m\($0.0)", sequence: $0.0, timestamp: "2026-10-25T12:00:00Z", sender: $0.1,
                           content: .text("Message \($0.0)"))
        }, lead: lead, members: [ChannelAgent(id: "ada", name: "Ada")], unreadAfter: 3,
           calendar: Calendar(identifier: .gregorian))
        let items = TranscriptItem.items(rows)

        #expect(items.map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(items.map(\.order) == [0, 1, 2, 3])
        #expect(items.map(\.sequence) == [1, 2, 3, 4])
        #expect(items.map(\.spacing) == [0, TranscriptSpacing.run, TranscriptSpacing.entry, TranscriptSpacing.divider])
        guard case .agent(_, _, let firstStarts) = items[1].content,
              case .agent(_, _, let secondStarts) = items[2].content else {
            Issue.record("Lead's run should become two agent entries.")
            return
        }
        #expect(firstStarts && !secondStarts)
        // A run's divider is drawn once, above its first entry.
        #expect(items[2].divider == nil)
        #expect(items[3].divider?.unread == true)
    }

    @Test func consecutiveSystemRowsStackAsOneGroupUntilADividerOrMessage() throws {
        func message(_ sequence: Int, day: Int = 1, system kind: String? = nil) -> ChannelMessage {
            ChannelMessage(id: "m\(sequence)", sequence: sequence,
                           timestamp: String(format: "2026-10-%02dT10:%02d:00Z", day, sequence),
                           sender: kind == nil ? .agent("lead") : .system,
                           content: kind.map { .system(.init(type: $0)) } ?? .text("Progress"))
        }
        let rows = TranscriptRowBuilder().rows([
            message(1), message(2, system: "member_joined"), message(3, system: "member_left"),
            message(4, day: 2, system: "tasks_completed"), message(5, day: 2, system: "channel_renamed"),
            message(6, day: 2), message(7, day: 2, system: "tasks_completed"),
        ], lead: ChannelAgent(id: "lead", name: "Lead"), members: [])
        try #require(rows.count == 7)
        #expect(rows[3].divider?.day != nil)
        #expect(TranscriptItem.items(rows).dropFirst().map(\.spacing) == [20, 4, 16, 4, 20, 20])
    }

    @Test func reactionGroupsPutTheMessagesOwnReactionsBeforeStatusReactions() {
        let agents = ["lead", "ada", "finch"].map { ChannelAgent(id: $0, name: $0.capitalized) }
        let message = ChannelMessage(id: "m14", sequence: 14, timestamp: "2026-10-22T17:23:00.000Z",
                                     sender: .user, content: .text("Ship it"),
                                     reactions: [.init(agentId: "lead", reaction: "done")])
        let status: [ChannelReaction] = [.init(agentId: "ada", reaction: "working"),
                                         .init(agentId: "finch", reaction: "looking"),
                                         .init(agentId: "finch", reaction: "working")]
        let groups = ChannelReactionGroup.groups(for: message, agents: agents, statusReactions: status)
        #expect(groups.map { "\($0.reaction) \($0.agents.map(\.id))" }
                == ["done [\"lead\"]", "working [\"ada\", \"finch\"]", "looking [\"finch\"]"])
        #expect(ChannelReactionGroup.groups(for: message, agents: agents).map(\.reaction) == ["done"])
    }

    @MainActor
    @Test func reactionPillShowsThreeFacesThenCountsTheRest() throws {
        #expect(TranscriptReactionPill.overflow(1) == nil)
        #expect(TranscriptReactionPill.overflow(3) == nil)
        #expect(TranscriptReactionPill.overflow(5) == "+2")
        let agents = (1...5).map { ChannelAgent(id: "agent-\($0)", name: "Agent \($0)") }
        func size<Content: View>(_ content: Content) throws -> (width: Int, height: Int) {
            let renderer = ImageRenderer(content: content.font(.system(size: 11)).fixedSize())
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return (image.width, image.height)
        }
        func pill(_ count: Int) throws -> (width: Int, height: Int) {
            try size(TranscriptReactionPill(emoji: "\u{2705}", reactors: Array(agents.prefix(count)),
                                            font: .system(size: 11), avatarSize: 14, height: 24))
        }
        let one = try pill(1), three = try pill(3), five = try pill(5)
        #expect([one, three, five].allSatisfy { $0.height == 24 })
        #expect(three.width - one.width == 2 * (14 + 4))
        let plusTwo = try size(Text("+2").monospacedDigit()).width
        #expect(abs(five.width - three.width - (4 + plusTwo)) <= 1)
    }

    @Test func onlyThePhonesBlackDarkCanvasLiftsTheUserBubble() {
        for isDark in [false, true] {
            for surface in [TranscriptSurface.canvas, .agent, .user, .pendingAgent, .notSentUser] {
                let fills = surface.fills(isDark: isDark)
                let lifted = surface == .user && isDark ? TranscriptSurface.agent.fills(isDark: true) + fills : fills
                #expect(surface.fills(isDark: isDark, canvasIsBlack: true) == lifted, "\(surface) dark \(isDark)")
            }
        }
    }

    @MainActor
    @Test func longMessagesCollapseInTheSamePassThatMeasuresThem() throws {
        func height(_ view: some View) throws -> CGFloat {
            let renderer = ImageRenderer(content: view.frame(width: 300).fixedSize(horizontal: false, vertical: true))
            renderer.scale = 1
            return CGFloat(try #require(renderer.cgImage).height)
        }
        func body(_ text: String) -> some View { Text(text).font(.system(size: 14)) }
        func collapsible(_ text: String, expanded: Bool) throws -> CGFloat {
            try height(TranscriptCollapsibleBody(isExpanded: expanded, spacing: 6, endPadding: 10) { body(text) }
                toggle: { Color.clear.frame(height: 20) })
        }
        let long = Array(repeating: "A line that wraps across the bubble.", count: 30).joined(separator: "\n")
        // A first measurement that comes back clamped means the row never changes height after it's placed.
        #expect(try collapsible(long, expanded: false) == TranscriptCollapsibleBody<Text, Text>.clampHeight + 26)
        #expect(abs(try collapsible(long, expanded: true) - (try height(body(long)) + 26)) <= 1)
        #expect(abs(try collapsible("Short", expanded: false) - (try height(body("Short")) + 10)) <= 1)
    }

    @Test func aTapOnAWrappedReactionPillOpensThatPillAndOuterRowsKeepTheirReach() {
        // 24-point pills in 44-point targets, rows 6 points apart like the phone's.
        let pill: CGFloat = 24
        let flow = TranscriptReactionFlow(spacing: 6, lineSpacing: 6 - (44 - pill))
        let frames = flow.frames(for: Array(repeating: CGSize(width: 120, height: 44), count: 3), width: 305)
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        let targets = frames.map { TranscriptReactionFlow.target(of: $0, in: bounds, rowOverlap: -flow.lineSpacing) }
        // Later chips draw above earlier ones, so the last target holding a point receives the tap.
        func chip(at y: CGFloat, x: CGFloat = 60) -> Int? {
            targets.lastIndex { $0.contains(CGPoint(x: x, y: y)) }
        }
        #expect(frames.map(\.minY) == [0, 0, 30])
        let upperPill = frames[0].midY - pill / 2..<frames[0].midY + pill / 2
        let lowerPill = frames[2].midY - pill / 2..<frames[2].midY + pill / 2
        #expect(chip(at: upperPill.upperBound - 2) == 0)
        #expect(chip(at: lowerPill.lowerBound + 2) == 2)
        #expect(chip(at: 36.9) == 0 && chip(at: 37) == 2)
        #expect(chip(at: 0) == 0 && chip(at: bounds.maxY - 0.1) == 2)
        #expect(chip(at: 0, x: 186) == 1)
    }
}

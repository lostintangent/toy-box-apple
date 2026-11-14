import ToyBoxKit
import Foundation
import SwiftUI
import Testing
import ToyBoxUI

@Suite("Shared transcript message parts")
struct TranscriptMessageTests {
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

    @Test func attachmentEdgeKeepsTheMacsOpacities() {
        typealias Edge = TranscriptAttachmentEdge<RoundedRectangle>
        #expect(Edge.opacity(isDark: false, increasedContrast: false) == 0.1)
        #expect(Edge.opacity(isDark: true, increasedContrast: false) == 0.14)
        #expect(Edge.opacity(isDark: false, increasedContrast: true) == 0.4)
        #expect(Edge.opacity(isDark: true, increasedContrast: true) == 0.4)
    }

    @Test func onlyThePhonesBlackDarkCanvasLiftsTheUserBubble() {
        let wash = Color.accentColor.opacity(0.09)
        for isDark in [false, true] {
            let neutral = Color.primary.opacity(isDark ? 0.07 : 0.045)
            let orange = Color.orange.opacity(0.10), red = Color.red.opacity(0.10)
            let mac: [TranscriptSurface: [Color]] = [
                .canvas: [], .agent: [neutral], .user: [wash], .pendingAgent: isDark ? [neutral, orange] : [orange],
                .notSentUser: isDark ? [neutral, red] : [red],
            ]
            for (surface, fills) in mac {
                #expect(surface.fills(isDark: isDark) == fills)
                #expect(surface.fills(isDark: isDark, canvasIsBlack: true) == (surface == .user && isDark
                    ? [neutral, wash] : fills))
            }
        }
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

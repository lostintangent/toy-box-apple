@testable import ToyBoxClient
import ToyBoxKit
import CoreGraphics
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import ToyBoxMobile
import ToyBoxUI
import UIKit

@Suite("Mobile Transcript")
@MainActor
struct TranscriptTests {
    private let lead = ChannelAgent(id: "lead", name: "Lead")

    private func message(_ sequence: Int, _ sender: ChannelMessageSender, minute: Int = 0) -> ChannelMessage {
        ChannelMessage(id: "m\(sequence)", sequence: sequence,
                       timestamp: String(format: "2026-10-25T12:%02d:00Z", minute), sender: sender,
                       content: .text("Message \(sequence)"))
    }

    @Test func phoneFindIsOneSixtyPointRowWithAStableStatusSlotAndStacksAtAccessibilitySizes() {
        func size(_ view: some View, width: CGFloat, _ type: DynamicTypeSize = .large) -> CGSize {
            UIHostingController(rootView: view.environment(\.dynamicTypeSize, type))
                .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        let states: [TranscriptFindStatus] = [.blank, .progress, .result("7 of 13"), .result("No matches"),
                                              .incomplete(error: "The connection was lost.")]
        // Every status, including Incomplete's 44-point target, keeps the slot one footnote line tall.
        let line = size(Text(verbatim: " ").font(.footnote), width: 300).height
        for status in states {
            let slot = TranscriptFindStatusView(status: status, found: "", showsError: .constant(false)) {}
            #expect(size(slot, width: 300) == CGSize(width: 84, height: line), "\(status)")
        }
        let find = TranscriptFind()
        find.present()
        find.query = "layout"
        let bar = TranscriptFindAccessory(find: find, channelName: "Studio demo", focusRequest: UUID(),
                                          navigate: { _ in }, close: {})
        // The folded Duo's bar measures 382 points in the native frame. The unfolded conversation column
        // with Overview open is wider, so every width from just under that up keeps one 44-point row
        // inside the composer's 8-point margins, 60 points in all.
        for width in [380, 386, 400, 454, 480, 560, 720] as [CGFloat] {
            #expect(size(bar, width: width).height.rounded() == 60, "\(width)")
        }
        find.query = String(repeating: "a long typed query ", count: 4)
        #expect(size(bar, width: 380).height.rounded() == 60)
        // The full-width field sits above the controls instead of shrinking type.
        #expect(size(bar, width: 386, .accessibility5).height > 2 * 44)

        // Status sits beside a query that keeps 64 points, and otherwise wraps below it.
        let field = TranscriptFindFieldLayout {
            Color.clear.frame(minWidth: 20 + TranscriptFindFieldLayout.minimumQueryWidth, maxWidth: .infinity,
                              minHeight: 30, maxHeight: 30)
            Color.clear.frame(width: 84, height: 20)
        }
        #expect(size(field, width: 84 + 4 + 84) == CGSize(width: 172, height: 30))
        #expect(size(field, width: 171) == CGSize(width: 171, height: 30 + 4 + 20))
    }

    @Test func phoneFindPlacesFieldAndCloseOnOneRowInTheFoldedDuosMeasuredBar() async throws {
        let find = TranscriptFind()
        find.present()
        find.query = "checkpoint"
        // The folded Duo's native frame gives the bar 382 points, so this hosts it just under that.
        let host = UIHostingController(rootView: TranscriptFindAccessory(
            find: find, channelName: "History demo", focusRequest: UUID(), navigate: { _ in }, close: {})
            .frame(maxHeight: .infinity, alignment: .top).dynamicTypeSize(.large))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 380, height: 300))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()

        func views(in view: UIView) -> [UIView] { view.subviews + view.subviews.flatMap(views) }
        let field = try #require(views(in: host.view).first { $0 is UITextField })
        let fieldFrame = field.convert(field.bounds, to: window)
        let close = try #require(MobileAutomationTree(windows: [window]).elements.first { $0.label == "Close Find" })
        #expect(abs(close.frame.midY - fieldFrame.midY) < 1, "field \(fieldFrame), Close \(close.frame)")
        #expect(close.frame.maxX <= 380 - 12 + 0.5)
        #expect(close.frame.height.rounded() == 44)
    }

    @Test func phoneFindKeepsMatchTextReadableInBothAppearances() throws {
        func rgb(_ color: UIColor, _ traits: UITraitCollection) -> TranscriptRGB {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return TranscriptRGB(red: red, green: green, blue: blue, alpha: alpha)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            for isCurrent in [false, true] {
                let run = try #require(TranscriptFindHighlight.phone(query: "hit", isCurrent: isCurrent)
                    .applying(to: AttributedString("a hit")).runs.first { $0.backgroundColor != nil })
                #expect(run.backgroundColor == Color(uiColor: .systemYellow).opacity(isCurrent ? 1 : 0.45))
                #expect(run.foregroundColor == (isCurrent ? Color.black : Color(uiColor: .label)))
                var fill = rgb(.systemYellow, traits)
                fill.alpha = isCurrent ? 1 : 0.45
                let ink = rgb(isCurrent ? .black : .label, traits)
                #expect(ink.contrast(with: rgb(.systemBackground, traits).under(fill)) >= 4.5)
            }
        }
    }

    @Test func theGalleryShowsOnlyTheMessagesImagesAndNeverWraps() throws {
        let attachments = [
            ChannelAttachment(name: "one.png", url: "/files/one.png", mimeType: "image/png"),
            ChannelAttachment(name: "notes.txt", url: "/files/notes.txt", mimeType: "text/plain"),
            ChannelAttachment(name: "diagram.svg", url: "/files/diagram.svg", mimeType: "image/svg+xml"),
            ChannelAttachment(name: "two.jpg", url: "/files/two.jpg", mimeType: "image/jpeg"),
            ChannelAttachment(name: "three.heic", url: "/files/three.heic"),
        ]
        let images = TranscriptGallery.images(in: attachments)
        #expect(images.map(\.name) == ["one.png", "two.jpg", "three.heic"])

        let gallery = TranscriptGallery()
        let api = try ChannelAPI(serverURL: "http://127.0.0.1:3210")
        let source = TranscriptImageSource(messageID: "m1", sender: "Lead",
                                                       timestamp: "2026-10-25T12:00:00Z")
        gallery.open(images: images, at: 7, source: source, api: api)
        #expect(gallery.session?.index == 2)
        #expect(gallery.session?.canShowNext == false)
        gallery.move(by: 1)
        #expect(gallery.session?.index == 2)
        gallery.select(0)
        #expect(gallery.session?.index == 0)
        #expect(gallery.session?.direction == -1)
        #expect(gallery.session?.canShowPrevious == false)
        gallery.move(by: -1)
        #expect(gallery.session?.index == 0)
        #expect(gallery.session.map(TranscriptGallery.accessibilityLabel) == "Image 1 of 3 from Lead, one.png")

        gallery.close()
        #expect(gallery.session == nil)
        gallery.open(images: [], at: 0, source: source, api: api)
        #expect(gallery.session == nil)
    }

    @Test func transcriptMetadataInkClearsTextContrastOnItsBackgroundsInBothAppearances() {
        func rgb(_ style: UIUserInterfaceStyle, _ color: UIColor) -> TranscriptRGB {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return TranscriptRGB(red: red, green: green, blue: blue, alpha: alpha)
        }
        let ink = UIColor(TranscriptInk.secondary)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let base = rgb(style, .systemBackground)
            // The transcript and gallery, Find's filled field and attachment cards.
            for background in [base, base.under(rgb(style, .tertiarySystemFill)), rgb(style, .secondarySystemBackground)] {
                #expect(background.under(rgb(style, ink)).contrast(with: background) >= 4.5)
            }
        }
    }

    @Test func workingNowStatusInkClearsTextContrastOnTheSheet() {
        func rgb(_ traits: UITraitCollection, _ color: UIColor) -> TranscriptRGB {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return TranscriptRGB(red: red, green: green, blue: blue, alpha: alpha)
        }
        let ink = UIColor(ChannelInk.secondary)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection {
                $0.userInterfaceStyle = style
                $0.userInterfaceLevel = .elevated
            }
            var backgrounds = [rgb(traits, .systemBackground), rgb(traits, .secondarySystemBackground)]
            // The darkest and lightest glass Designer sampled behind Ada and Pixel in Dark.
            if style == .dark {
                backgrounds += [TranscriptRGB(red: 0x21 / 255, green: 0x21 / 255, blue: 0x21 / 255, alpha: 1),
                                TranscriptRGB(red: 0x3D / 255, green: 0x3D / 255, blue: 0x3D / 255, alpha: 1)]
            }
            for background in backgrounds {
                #expect(background.under(rgb(traits, ink)).contrast(with: background) >= 4.5)
            }
        }
    }

    @Test func mentionsUseTheAgentsInkAtTextContrastOnEveryBubble() throws {
        let pale = ChannelAgent(id: "ada", name: "Ada", avatar: .init(mark: "M0 0", color: "#facc15"))
        let text = transcriptInlineMarkdown("Thanks @ada and @everyone, not @nobody", agents: [pale],
                                            mentionInk: { _ in .red })
        let styled = text.runs.filter { $0.foregroundColor != nil }.map { String(text[$0.range].characters) }
        #expect(styled == ["@ada", "@everyone"])
        for dark in [false, true] {
            for increased in [false, true] {
                // The same traits production resolves with, so 7:1 is measured on the high-contrast canvas.
                let traits = UITraitCollection {
                    $0.userInterfaceStyle = dark ? .dark : .light
                    $0.accessibilityContrast = increased ? .high : .normal
                }
                func rgb(_ color: Color) -> TranscriptRGB {
                    var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
                    UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    return TranscriptRGB(red: red, green: green, blue: blue, alpha: alpha)
                }
                for surface in [TranscriptSurface.agent, .pendingAgent, .user, .notSentUser] {
                    let ink = rgb(TranscriptMentionInk(surface: surface, isDark: dark, isContrastIncreased: increased)
                        .color(for: pale))
                    let background = surface.fills(isDark: dark, canvasIsBlack: true)
                        .reduce(rgb(Color(uiColor: .systemBackground))) { $0.under(rgb($1)) }
                    #expect(ink.contrast(with: background) >= (increased ? 7 : 4.5))
                }
            }
        }
    }

    @Test func fiveReactionKindsWrapIntoTwoRowsWhenFoldedAndStillFitAtTheLargestSize() {
        let agents = (1...5).map { ChannelAgent(id: "a\($0)", name: "Agent \($0)") }
        let kinds: [(String, Int)] = [("done", 5), ("agree", 1), ("celebrate", 3), ("love", 2), ("laugh", 1)]
        let reactions = kinds.flatMap { kind, count in
            agents.prefix(count).map { ChannelReaction(agentId: $0.id, reaction: kind) }
        }
        let message = ChannelMessage(id: "m", sequence: 1, timestamp: "2026-10-25T12:00:00Z",
                                     sender: .agent("a1"), content: .text("Reacted"), reactions: reactions)
        // The folded phone's agent bubble column, measured in the native frame.
        let column = CGSize(width: 305, height: CGFloat.infinity)
        func size(_ type: DynamicTypeSize) -> CGSize {
            UIHostingController(rootView: TranscriptReactions(message: message, agents: agents)
                .environment(\.dynamicTypeSize, type)).sizeThatFits(in: column)
        }

        let folded = size(.large)
        #expect(folded.width <= column.width)
        // Two rows of 44-point targets, 6 points apart between their 24-point pills.
        let twoRows: CGFloat = 44 + 24 + 6
        #expect(folded.height.rounded() == twoRows, "\(folded.height)")
        #expect(size(.accessibility5).width <= column.width)
    }

    @Test func voiceOverReadsWrappedReactionsRowByRowInTheirOrder() async {
        let agents = (1...5).map { ChannelAgent(id: "a\($0)", name: "Agent \($0)") }
        let kinds: [(String, Int)] = [("done", 5), ("agree", 1), ("celebrate", 3), ("love", 2), ("laugh", 1)]
        let reactions = kinds.flatMap { kind, count in
            agents.prefix(count).map { ChannelReaction(agentId: $0.id, reaction: kind) }
        }
        let message = ChannelMessage(id: "m", sequence: 1, timestamp: "2026-10-25T12:00:00Z",
                                     sender: .agent("a1"), content: .text("Reacted"), reactions: reactions)
        let host = UIHostingController(rootView: TranscriptReactions(message: message, agents: agents)
            .frame(width: 305, alignment: .leading).dynamicTypeSize(.large))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 305, height: 400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()

        let expected = ChannelReactionGroup.groups(for: message, agents: agents).map(\.presentation.label)
        let chips = MobileAutomationTree(windows: [window]).elements.filter { element in
            expected.contains { element.label.hasPrefix("\($0): ") }
        }
        #expect(chips.map { String($0.label.prefix { $0 != ":" }) } == expected)
        let rows = chips.map { $0.frame.midY.rounded() }
        #expect(Set(rows).count == 2, "\(chips.map(\.frame))")
        for (previous, next) in zip(chips, chips.dropFirst()) {
            let sameRow = previous.frame.midY.rounded() == next.frame.midY.rounded()
            #expect(sameRow ? next.frame.minX > previous.frame.maxX : next.frame.midY > previous.frame.midY,
                    "\(previous.label) then \(next.label)")
        }
    }

    @Test func aMiddleRowOfReactionTargetsGivesHalfOfEachGapToItsNeighbors() async {
        // Three rows of 44-point targets around 24-point pills, measured natively in each chip's space.
        let flow = TranscriptReactionFlow(spacing: 6, lineSpacing: -14)
        var targets: [Int: CGRect] = [:]
        let host = UIHostingController(rootView: flow {
            ForEach(0..<3) { row in
                Color.clear.frame(width: 200, height: 44).background {
                    GeometryReader { proxy in
                        let target = TranscriptReactionFlow.target(in: proxy, rowOverlap: 14)
                        Color.clear.onAppear { targets[row] = target }
                    }
                }
            }
        }
        .coordinateSpace(.named(TranscriptReactionFlow.coordinateSpace))
        .frame(width: 305, alignment: .topLeading))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 305, height: 400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()

        #expect(targets[0] == CGRect(x: 0, y: 0, width: 200, height: 37))
        #expect(targets[1] == CGRect(x: 0, y: 7, width: 200, height: 30))
        #expect(targets[2] == CGRect(x: 0, y: 7, width: 200, height: 37))
    }

    @Test func unfoldedMessagesUseTheWholeColumnUpToTheMacsReadingCaps() async throws {
        final class Frames { var agent = CGRect.zero, mine = CGRect.zero }
        // Folded keeps 88% for your messages. Unfolded, a wide column adds air instead of longer lines.
        let cases: [(width: CGFloat, fraction: CGFloat, agent: CGFloat, mine: CGFloat)] = [
            (402, 0.88, 402, 353.76), (700, 0.8, 700, 560), (1_000, 0.8, 760, 640), (1_400, 0.8, 760, 640),
        ]
        for (width, fraction, agent, mine) in cases {
            let frames = Frames()
            // Greedy stand-ins take every point offered, so they measure each cap itself.
            let view = VStack(spacing: 0) {
                Color.clear.frame(height: 20)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.agent = $0 }
                    .transcriptWidthCap(TranscriptWidthCap.agentSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TranscriptUserLane(maxWidth: TranscriptUserLane.maximumWidth, fraction: fraction) {
                    Color.clear.frame(height: 20)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.mine = $0 }
                }
            }
            .frame(width: width)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 200))
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.isHidden = false
            try await waitUntil("both lanes measured at \(width)", in: host.view) {
                frames.agent != .zero && frames.mine != .zero
            }
            window.isHidden = true
            #expect(abs(frames.agent.width - agent) < 0.5, "\(width): agent \(frames.agent)")
            #expect(abs(frames.agent.minX) < 0.5)
            #expect(abs(frames.mine.width - mine) < 0.5, "\(width): mine \(frames.mine)")
            #expect(abs(frames.mine.maxX - width) < 0.5)
        }
    }

    @Test func aMessageStaysInsideItsColumnAtEveryTextSize() throws {
        let api = try ChannelAPI(serverURL: "https://column-\(UUID().uuidString.lowercased()).invalid")
        let question = "Where should the shared library sit? Reply with your preference and any constraints."
        func width(_ text: String, request: Bool, answered: Bool = false, size: DynamicTypeSize) -> CGFloat {
            let ask = ChannelMessage(id: "m1", sequence: 1, timestamp: "2026-10-25T12:00:00Z",
                                     sender: .agent("lead"), content: .text(text), request: request)
            let answer = ChannelMessage(id: "m2", sequence: 2, timestamp: "2026-10-25T12:01:00Z",
                                        sender: .user, content: .text("Near the entrance"))
            let rows = TranscriptRowBuilder().rows(answered ? [ask, answer] : [ask], lead: lead, members: [],
                                                   calendar: Calendar(identifier: .gregorian))
            guard case .agent(_, let entries) = rows[0].content else { return .infinity }
            let view = TranscriptAgentMessage(entry: entries[0], agent: lead,
                                              channel: TranscriptRowChannel(id: "rows", agents: [lead], api: api),
                                              statusReactions: [])
                .environment(ChannelInteraction()).dynamicTypeSize(size)
            return UIHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).width
        }
        // The folded Duo's column is about 300 points beside the toolbar. "Needs your reply" alone is
        // wider than that at the largest size, and a long word must break inside the bubble.
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            #expect(width(question, request: true, size: size) <= 300, "\(size) pending")
            #expect(width(question, request: true, answered: true, size: size) <= 300, "\(size) replied")
            #expect(width("Supercalifragilisticexpialidocious", request: false, size: size) <= 300, "\(size) word")
        }
    }

    @Test func attachmentsShareOneRowThatScrollsSideways() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format)
            .image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            }.pngData()).base64EncodedString()
        let attachments = ["one.png", "two.png", "three.png"].map {
            ChannelAttachment(name: $0, mimeType: "image/png", base64: png)
        } + [ChannelAttachment(name: "A very long attachment name that would otherwise stretch across the row.txt",
                               url: "/files/notes.txt", mimeType: "text/plain")]
        let api = try ChannelAPI(serverURL: "https://strip-\(UUID().uuidString.lowercased()).invalid")
        let tile = ChannelThumbnails.boxSize(fitting: CGSize(width: 400, height: 300))
        let host = UIHostingController(rootView: TranscriptAttachments(
            attachments: attachments, api: api, alignment: .trailing,
            source: .init(messageID: "m1", sender: "Lead", timestamp: "2026-10-26T12:00:00Z")))
        // Measure the strip alone, without the window's home indicator inset.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        // One row as tall as an image, where a stack would be four tiles tall.
        let height = host.sizeThatFits(in: CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude)).height
        #expect(abs(height - tile.height) < 0.5)
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let strip = try #require(scrollViews(host.view).first)
        // Three images and the file row, 8 points apart with 4 points of shadow room at each end,
        // overflow and scroll sideways.
        #expect(strip.contentSize.width > 402)
        let fileRow = strip.contentSize.width - 3 * tile.width - 3 * 8 - 2 * 4
        // The long name truncates at 200 points, so the row is its label plus the icon and padding.
        #expect(fileRow > 200 && fileRow < 260, "file row \(fileRow)")
    }

    /// Unfolded, the split view keeps one channel screen and swaps its store. Message numbers count
    /// per channel, so a quieter channel opened after reading a busy one still marks itself read.
    @Test func switchingToAChannelWithLowerSequencesStillMarksItRead() async throws {
        let suite = "transcript-switch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = "https://switch-\(UUID().uuidString.lowercased()).invalid"
        let model = AppModel(arguments: ["--server", server], environment: [:], defaults: defaults,
                             session: fixtureSession())
        model.setScenePhase(.active)
        defer { model.setScenePhase(.background) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadRecordingProtocol.self]
        let api = try ChannelAPI(serverURL: server, session: URLSession(configuration: configuration))
        func store(_ id: String, through latest: Int, seen: Int) throws -> ChannelStore {
            let store = ChannelStore(id: id, api: api)
            _ = try store.apply(.init(type: "snapshot", state: ChannelState(
                revision: 1,
                channel: Channel(id: id, name: id, model: .init(provider: "test", name: "test"),
                                 latestSequence: latest, seenThrough: seen, updatedAt: "2026-10-25T12:00:00Z"),
                lead: .lead(id: "lead", profile: .init(name: "Lead", role: "Coordinator",
                                                      avatar: .init(mark: "M4 12H20", color: "#123456"))),
                members: [], messages: (latest - 39...latest).map { message($0, .user) })))
            return store
        }
        let busy = try store("busy", through: 400, seen: 395)
        let quiet = try store("quiet", through: 40, seen: 35)
        let shown = ShownChannel(busy)
        // The navigation shows the selected channel.
        model.showsSelection = true
        model.selection = busy.target
        let host = UIHostingController(rootView: SwitchingChannelScreen(shown: shown)
            .environment(model)
            .environment(model.following)
            .environment(ManagementPresenter())
            .environment(Overview())
            .environment(\.horizontalSizeClass, .regular)
            .environment(\.scenePhase, .active))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 669, height: 951))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        func reads(_ expected: [String]) async throws {
            try await waitUntil("reads \(expected), got \(ReadRecordingProtocol.reads(on: server))", in: host.view) {
                ReadRecordingProtocol.reads(on: server) == expected
            }
        }
        try await reads(["busy 400"])
        model.selection = quiet.target
        shown.store = quiet
        try await reads(["busy 400", "quiet 40"])
    }
}


@MainActor @Observable
private final class ShownChannel {
    var store: ChannelStore
    init(_ store: ChannelStore) { self.store = store }
}

/// Like the unfolded split view's detail, one channel screen whose store changes in place.
private struct SwitchingChannelScreen: View {
    let shown: ShownChannel
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = shown.store
        NavigationStack {
            ChannelScreen(store: store)
        }
        .environment(model.interaction(for: store.target!))
        .environment(model.artifactSession(for: store))
        .environment(model.gallery(for: store))
    }
}

/// Answers every read with the sequence it asked for and records it, per server, as "channel sequence".
private final class ReadRecordingProtocol: URLProtocol, @unchecked Sendable {
    private static let recorded = Mutex<[String: [String]]>([:])

    static func reads(on server: String) -> [String] {
        recorded.withLock { $0[URL(string: server)?.host ?? ""] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let components = url.pathComponents
        guard request.httpMethod == "POST", components.last == "read", components.count >= 2,
              let body = Self.body(of: request),
              let sequence = (try? JSONSerialization.jsonObject(with: body) as? [String: Int])?["sequence"] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let channel = components[components.count - 2]
        Self.recorded.withLock { $0[url.host ?? "", default: []].append("\(channel) \(sequence)") }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"seenThrough":\#(sequence)}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

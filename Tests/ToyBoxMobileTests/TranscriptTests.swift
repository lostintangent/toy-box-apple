@testable import ChannelClient
import ChannelKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ToyBoxMobile
import ToyBoxUI
import UIKit

@Suite("Mobile Transcript")
@MainActor
struct TranscriptTests {
    private let lead = ChannelAgent(id: "lead", name: "Lead")
    private let ada = ChannelAgent(id: "ada", name: "Ada")

    private func message(_ sequence: Int, _ sender: ChannelMessageSender, minute: Int = 0) -> ChannelMessage {
        ChannelMessage(id: "m\(sequence)", sequence: sequence,
                       timestamp: String(format: "2026-10-25T12:%02d:00Z", minute), sender: sender,
                       content: .text("Message \(sequence)"))
    }

    @Test func runsSplitIntoEntriesThatEachMarkTheirOwnSequence() {
        let messages = [
            message(1, .user),
            message(2, .agent("lead")),
            message(3, .agent("lead")),
            message(4, .agent("ada")),
        ]
        let rows = transcriptRows(messages, lead: lead, members: [ada], unreadAfter: 3,
                                  calendar: Calendar(identifier: .gregorian))
        let items = transcriptItems(rows)

        #expect(items.map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(items.map(\.order) == [0, 1, 2, 3])
        #expect(items.map(\.sequence) == [1, 2, 3, 4])
        #expect(items.map(\.spacing) == [0, TranscriptSpacing.run, TranscriptSpacing.entry, TranscriptSpacing.run])
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

    @Test func readingAPositionWaitsForAMeasuredRowInView() {
        let viewport = TranscriptScrollModel.Viewport(width: 386, height: 600, topInset: 0, bottomInset: 0)
        let scroll = TranscriptScroll()
        scroll.rows = (0..<10).map { .init(id: "r\($0)", order: $0) }
        for index in 0..<10 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        scroll.metrics = .init(viewport: viewport, origin: 400, documentEnd: 1000)
        #expect(scroll.update(.land(.end)) != nil)

        // An older page lands above, but the lazy stack hasn't reported it while it's on screen.
        scroll.rows = (0..<5).map { .init(id: "p\($0)", order: $0) }
            + (0..<10).map { .init(id: "r\($0)", order: $0 + 5) }
        for index in 0..<10 {
            scroll.measure("r\(index)", frame: CGRect(x: 0, y: 1000 + CGFloat(index) * 100, width: 386, height: 100))
        }
        scroll.metrics = .init(viewport: viewport, origin: 100, documentEnd: 2000)
        scroll.isReaderScrolling = true
        #expect(scroll.update() == nil)

        for index in 0..<5 { scroll.measure("p\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 200, width: 386, height: 200)) }
        #expect(scroll.update() != nil)
        guard case .reading(let anchor) = scroll.intent else {
            Issue.record("Scrolling should leave the reader where they are.")
            return
        }
        // The first measured row starting below the top holds the reader's place.
        #expect(anchor.row == "p1" && anchor.offset == 100)
    }

    @Test func aRevealFinishesFromSettledGeometryOrWhenTheReaderTakesOver() {
        let viewport = TranscriptScrollModel.Viewport(width: 386, height: 600, topInset: 0, bottomInset: 0)
        let scroll = TranscriptScroll()
        scroll.rows = (0..<20).map { .init(id: "r\($0)", order: $0) }
        for index in 0..<20 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        scroll.metrics = .init(viewport: viewport, origin: 1400, documentEnd: 2000)
        _ = scroll.update(.land(.end))

        // Asking to scroll isn't revealing: it finishes only once the native origin arrives.
        let settles = UUID()
        scroll.pendingReveal = (settles, "r5")
        let origin = scroll.update(.reveal("r5"))?.origin
        #expect(origin == 250 && scroll.finishedReveal() == nil)
        scroll.metrics?.origin = 250
        _ = scroll.update()
        #expect(scroll.finishedReveal()! == (settles, true))
        #expect(scroll.finishedReveal() == nil)

        // The reader scrolling first finishes it, revealed only if the row ended up in view.
        let interrupted = UUID()
        scroll.pendingReveal = (interrupted, "r15")
        #expect(scroll.update(.reveal("r15"))?.origin == 1250 && scroll.finishedReveal() == nil)
        scroll.isReaderScrolling = true
        scroll.metrics?.origin = 0
        _ = scroll.update()
        #expect(scroll.finishedReveal()! == (interrupted, false))
    }

    @Test func aRevealIntoAPageThatJustLandedFindsItsRow() {
        let viewport = TranscriptScrollModel.Viewport(width: 386, height: 600, topInset: 0, bottomInset: 0)
        let scroll = TranscriptScroll()
        let loaded: [TranscriptScrollModel.RowIdentity] = (0..<20).map { .init(id: "r\($0)", order: $0 + 5) }
        scroll.sync(loaded)
        for index in 0..<20 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        scroll.metrics = .init(viewport: viewport, origin: 1400, documentEnd: 2000)
        _ = scroll.update(.land(.end))

        // The reveal resumes after older pages land but before SwiftUI reports the new rows.
        let paged = (0..<5).map { TranscriptScrollModel.RowIdentity(id: "p\($0)", order: $0) } + loaded
        #expect(scroll.update(.reveal("p2"))?.unavailableTarget == "p2")
        scroll.sync(paged)
        #expect(scroll.update(.reveal("p2"))?.unavailableTarget == nil)
        guard case .revealing("p2", _) = scroll.intent else {
            Issue.record("The reveal should own the position.")
            return
        }
        // SwiftUI's later report of the same rows must not hold the old position over the reveal.
        scroll.sync(paged)
        guard case .revealing("p2", _) = scroll.intent else {
            Issue.record("A repeated sync replaced the reveal.")
            return
        }
    }

    @Test func aPageArrivingAtTheTopKeepsTheReadersRowInsteadOfItsOldFrame() {
        let viewport = TranscriptScrollModel.Viewport(width: 386, height: 600, topInset: 0, bottomInset: 0)
        let scroll = TranscriptScroll()
        let loaded: [TranscriptScrollModel.RowIdentity] = (0..<20).map { .init(id: "r\($0)", order: $0 + 5) }
        scroll.sync(loaded)
        for index in 0..<20 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        scroll.metrics = .init(viewport: viewport, origin: 1400, documentEnd: 2000)
        _ = scroll.update(.land(.end))
        scroll.metrics?.origin = 30
        scroll.isReaderScrolling = true
        _ = scroll.update()

        // UIKit keeps the offset as the page lands above, so r1's old frame would say nothing moved.
        let paged = (0..<5).map { TranscriptScrollModel.RowIdentity(id: "p\($0)", order: $0) } + loaded
        scroll.sync(paged)
        scroll.metrics?.documentEnd = 2500
        #expect(scroll.update()?.needsMeasurement == "r1")
        #expect(!scroll.reachesOlder)

        for index in 0..<5 { scroll.measure("p\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        for index in 0..<20 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index + 5) * 100, width: 386, height: 100)) }
        #expect(scroll.update()?.origin == 530)
        #expect(!scroll.reachesOlder)
    }

    @Test func aMergedPageLoadsOnceEvenWhenGeometryArrivesBeforeItsRows() {
        let viewport = TranscriptScrollModel.Viewport(width: 386, height: 600, topInset: 0, bottomInset: 0)
        let scroll = TranscriptScroll()
        let loaded: [TranscriptScrollModel.RowIdentity] = (0..<20).map { .init(id: "r\($0)", order: $0 + 5) }
        scroll.sync(loaded)
        for index in 0..<20 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        scroll.metrics = .init(viewport: viewport, origin: 1400, documentEnd: 2000)
        _ = scroll.update(.land(.end))
        var store = loaded
        var loads = 0
        func geometry(origin: CGFloat, documentEnd: CGFloat) {
            scroll.metrics?.origin = origin
            scroll.metrics?.documentEnd = documentEnd
            _ = scroll.update()
            if scroll.loadsOlder(with: store) { loads += 1 }
        }

        scroll.isReaderScrolling = true
        geometry(origin: 40, documentEnd: 2000)
        #expect(loads == 1)

        // The page merges, and geometry reports the grown content before `onChange(items)` syncs it.
        store = (0..<5).map { .init(id: "p\($0)", order: $0) } + loaded
        for origin in stride(from: 39, through: 28, by: -1) { geometry(origin: CGFloat(origin), documentEnd: 2500) }
        #expect(scroll.reachesOlder, "The old rows make the grown content look settled.")
        #expect(loads == 1)

        scroll.sync(store)
        for index in 0..<5 { scroll.measure("p\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        for index in 0..<20 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index + 5) * 100, width: 386, height: 100)) }
        geometry(origin: 28, documentEnd: 2500)
        geometry(origin: 528, documentEnd: 2500)
        #expect(loads == 1)
    }

    @Test func aLandingThatCantFillTheScreenReachesOlderHistoryOnceItsPlaced() {
        let viewport = TranscriptScrollModel.Viewport(width: 386, height: 600, topInset: 0, bottomInset: 0)
        let scroll = TranscriptScroll()
        scroll.sync((0..<3).map { .init(id: "r\($0)", order: $0) })
        for index in 0..<3 { scroll.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        // Before landing, the initial offset says nothing about where the reader is.
        scroll.metrics = .init(viewport: viewport, origin: 0, documentEnd: 300 + TranscriptScrollModel.endClearance)
        #expect(!scroll.reachesOlder)
        let landing = scroll.update(.land(.end))
        #expect(landing?.origin == 0)
        #expect(scroll.reachesOlder)

        // A tall channel landed at its end is out of reach until the reader scrolls to the top.
        let tall = TranscriptScroll()
        tall.sync((0..<20).map { .init(id: "r\($0)", order: $0) })
        for index in 0..<20 { tall.measure("r\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 386, height: 100)) }
        tall.metrics = .init(viewport: viewport, origin: 1400, documentEnd: 2000)
        _ = tall.update(.land(.end))
        #expect(!tall.reachesOlder)
        tall.isReaderScrolling = true
        tall.metrics?.origin = 30
        _ = tall.update()
        #expect(tall.reachesOlder)
    }

    @Test func onlyANewSendFollowsToTheBottom() {
        func attempt(_ id: String, _ phase: ChannelSendPhase) -> ChannelSendAttempt {
            ChannelSendAttempt(id: id, content: id, attachments: [], timestamp: "2026-10-25T12:00:00Z", phase: phase)
        }
        // The restored outbox lands after the unread landing and must not move the reader.
        #expect(!startsOwnPost(after: [], in: [attempt("old", .deliveryNotConfirmed), attempt("lost", .notSent)]))
        #expect(startsOwnPost(after: ["old"], in: [attempt("old", .notSent), attempt("new", .sending)]))
        // Send Again reuses its id, so it isn't a new post.
        #expect(!startsOwnPost(after: ["old"], in: [attempt("old", .sending)]))
    }

    @Test func phoneFindRevealsOnlyOnNavigationAndSpeaksPartialPositionsAsProvisional() {
        let find = TranscriptFind()
        find.revealsWhileTyping = false
        find.prepare(messages: [
            ChannelMessage(id: "a", sequence: 4, timestamp: "2026-10-25T12:00:00Z", sender: .user, content: .text("hit")),
            ChannelMessage(id: "b", sequence: 6, timestamp: "2026-10-25T12:01:00Z", sender: .user, content: .text("hit"))
        ], agents: [lead], hasOlder: true)
        find.present()
        find.query = "hit"
        #expect(find.revealRequest == nil)
        #expect(find.isSearching)
        #expect(find.status(progressDelayElapsed: true) == .progress)
        find.move(1)
        #expect(find.revealRequest?.sequence == 4)
        find.move(1)
        #expect(find.revealRequest?.sequence == 6)
        #expect(find.navigationAnnouncement == "2 of 2 found so far, still searching")
        // Closing leaves the reader at the match. Only a real scroll or Jump to Latest reads again.
        find.close()
        #expect(find.blocksRead)
        find.resumeReading()
        #expect(!find.blocksRead)
    }

    @Test func phoneFindIsOneFiftyTwoPointRowWithAStableStatusSlotAndStacksAtAccessibilitySizes() {
        func size(_ view: some View, width: CGFloat, _ type: DynamicTypeSize = .large) -> CGSize {
            UIHostingController(rootView: view.environment(\.dynamicTypeSize, type))
                .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        let states: [TranscriptFindStatus] = [.blank, .progress, .result("7 of 13"), .result("No matches"),
                                              .incomplete(error: "The connection was lost.")]
        for status in states {
            let slot = TranscriptFindStatusView(status: status, found: "", showsError: .constant(false)) {}
            #expect(size(slot, width: 300).width == 84, "\(status)")
        }
        let find = TranscriptFind()
        find.present()
        find.query = "layout"
        let bar = TranscriptFindAccessory(find: find, channelName: "Studio demo", focusRequest: UUID(),
                                          navigate: { _ in }, close: {})
        // The folded Duo's bar measures 382 points in the native frame. The unfolded conversation column
        // with Overview open is wider, so every width from just under that up keeps one 52-point row.
        for width in [380, 386, 400, 454, 480, 560, 720] as [CGFloat] {
            #expect(size(bar, width: width).height.rounded() == 52, "\(width)")
        }
        find.query = String(repeating: "a long typed query ", count: 4)
        #expect(size(bar, width: 380).height.rounded() == 52)
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

    @Test func phoneFindPlacesFieldAndDoneOnOneRowInTheFoldedDuosMeasuredBar() async throws {
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
        let done = try #require(MobileAutomationTree(windows: [window]).elements.first { $0.label == "Close Find" })
        #expect(abs(done.frame.midY - fieldFrame.midY) < 1, "field \(fieldFrame), Done \(done.frame)")
        #expect(done.frame.maxX <= 380 - 16 + 0.5)
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
        let images = TranscriptGalleryPresenter.images(in: attachments)
        #expect(images.map(\.name) == ["one.png", "two.jpg", "three.heic"])

        let gallery = TranscriptGalleryPresenter()
        let api = try ChannelAPI(serverURL: "http://127.0.0.1:3210")
        let source = TranscriptGalleryPresenter.Source(messageID: "m1", sender: "Lead",
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
        #expect(gallery.session.map(TranscriptGalleryPresenter.accessibilityLabel) == "Image 1 of 3 from Lead, one.png")

        gallery.close()
        #expect(gallery.session == nil)
        gallery.open(images: [], at: 0, source: source, api: api)
        #expect(gallery.session == nil)
    }

    @Test func theGallerySubtitleCountsOnlySeveralImages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let sent = try #require(ChannelDates.date("2026-10-25T17:23:00Z"))
        let now = try #require(ChannelDates.date("2026-10-25T20:00:00Z"))
        func subtitle(_ index: Int, _ count: Int) -> String {
            TranscriptGalleryPresenter.subtitle(sentAt: sent, index: index, count: count, now: now, calendar: calendar)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(subtitle(1, 4) == "Today at 5:23 PM · 2 of 4")
        #expect(subtitle(0, 1) == "Today at 5:23 PM")
        #expect(TranscriptGalleryPresenter.subtitle(sentAt: nil, index: 2, count: 3) == "3 of 3")
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
                for surface in [TranscriptSurface.agent, .pendingAgent, .user] {
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

    @Test func messagesRenderMarkdownBlocksLikeTheMac() {
        func height(_ text: String) -> CGFloat {
            UIHostingController(rootView: TranscriptBody(text: text))
                .sizeThatFits(in: CGSize(width: 300, height: CGFloat.infinity)).height
        }
        let line = height("Pass 300")
        #expect(height("## Pass 300") > line * 1.2)
    }

    @Test func longMessagesCollapseInTheSamePassThatMeasuresThem() {
        func height(_ text: String, expanded: Bool) -> CGFloat {
            UIHostingController(rootView: TranscriptCollapsibleBody(isExpanded: expanded, endPadding: 10) {
                Text(text).font(.body)
            } toggle: {
                Button("Show More") {}.frame(minHeight: 44)
            }).sizeThatFits(in: CGSize(width: 300, height: CGFloat.infinity)).height
        }
        let long = Array(repeating: "A line that wraps across the bubble.", count: 30).joined(separator: "\n")
        let full = UIHostingController(rootView: Text(long).font(.body))
            .sizeThatFits(in: CGSize(width: 300, height: CGFloat.infinity)).height
        let short = UIHostingController(rootView: Text("Short").font(.body))
            .sizeThatFits(in: CGSize(width: 300, height: CGFloat.infinity)).height
        // A first measurement that comes back clamped means the row never changes height after it's placed.
        #expect(height(long, expanded: false) == TranscriptCollapsibleBody<Text, Text>.clampHeight + 44)
        #expect(abs(height(long, expanded: true) - (full + 44)) < 1)
        #expect(abs(height("Short", expanded: false) - (short + 10)) < 1)
    }

    @Test func galleryPagingUsesTheApprovedMotion() {
        #expect(TranscriptImageGallery.pageAnimation(reduceMotion: false) == .smooth(duration: 0.3))
        #expect(TranscriptImageGallery.pageAnimation(reduceMotion: true) == .easeInOut(duration: 0.2))
    }

    @Test func unfoldedMessagesUseTheWholeColumnUpToTheMacsReadingCaps() throws {
        #expect(TranscriptWidthCap.agentSurface == 760)
        #expect(TranscriptUserLane.maximumWidth == 640)
        #expect(transcriptEdgeInset(.compact) == 16)
        #expect(transcriptEdgeInset(.regular) == 20)
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
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: .now + 0.05)
            window.isHidden = true
            #expect(abs(frames.agent.width - agent) < 0.5, "\(width): agent \(frames.agent)")
            #expect(abs(frames.agent.minX) < 0.5)
            #expect(abs(frames.mine.width - mine) < 0.5, "\(width): mine \(frames.mine)")
            #expect(abs(frames.mine.maxX - width) < 0.5)
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
        let tile = transcriptThumbnailSize(CGSize(width: 400, height: 300))
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
}


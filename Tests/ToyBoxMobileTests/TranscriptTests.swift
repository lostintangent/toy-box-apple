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
        #expect(items.map(\.spacing) == [0, TranscriptItem.runGap, TranscriptItem.entryGap, TranscriptItem.runGap])
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

    @Test func phoneFindRevealsOnlyOnNavigationAndCallsProvisionalCountsSoFar() {
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
        #expect(find.phoneCountLabel == "1 of 2 so far")
        find.move(1)
        #expect(find.revealRequest?.sequence == 4)
        find.move(1)
        #expect(find.revealRequest?.sequence == 6)
        #expect(find.phoneCountLabel == "2 of 2 so far")
        // Closing leaves the reader at the match. Only a real scroll or Jump to Latest reads again.
        find.close()
        #expect(find.blocksRead)
        find.resumeReading()
        #expect(!find.blocksRead)
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
        func rgb(_ color: Color, dark: Bool) -> TranscriptRGB {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
                .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return TranscriptRGB(red: red, green: green, blue: blue, alpha: alpha)
        }
        let pale = ChannelAgent(id: "ada", name: "Ada", avatar: .init(mark: "M0 0", color: "#facc15"))
        let text = transcriptInlineMarkdown("Thanks @ada and @everyone, not @nobody", agents: [pale],
                                            mentionInk: { _ in .red })
        let styled = text.runs.filter { $0.foregroundColor != nil }.map { String(text[$0.range].characters) }
        #expect(styled == ["@ada", "@everyone"])
        for dark in [false, true] {
            for increased in [false, true] {
                for surface in [TranscriptSurface.agent, .pendingAgent, .user] {
                    let ink = rgb(TranscriptMentionInk(surface: surface, isDark: dark, isContrastIncreased: increased)
                        .color(for: pale), dark: dark)
                    let background = surface.fills(isDark: dark)
                        .reduce(rgb(Color(uiColor: .systemBackground), dark: dark)) { $0.under(rgb($1, dark: dark)) }
                    #expect(ink.contrast(with: background) >= (increased ? 7 : 4.5))
                }
            }
        }
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
}

import Foundation
import SwiftUI
import Testing
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// t1238 spike: plain SwiftUI with none of the transcript's code, measured against the transcript's
// cases on both platforms. Each case records what it measured to the spike's results file.

@MainActor @Observable
private final class SpikeConversation {
    struct Row: Identifiable, Equatable {
        let id: Int
        var words: Int
    }

    var rows: [Row]
    var position = ScrollPosition(idType: Int.self)
    var frames: [Int: CGRect] = [:]
    var geometry: ScrollGeometry?

    init(ids: ClosedRange<Int>) {
        rows = ids.map { Row(id: $0, words: Self.words(for: $0)) }
    }

    static func words(for id: Int) -> Int { 4 + (id * 37 % 11) * 9 }

    var gapBelow: CGFloat {
        guard let geometry else { return .nan }
        return geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
    }
    var contentHeight: CGFloat { geometry?.contentSize.height ?? 0 }
    var topRow: (id: Int, minY: CGFloat)? {
        frames.filter { $0.value.maxY > 0 }.min { $0.value.minY < $1.value.minY }.map { ($0.key, $0.value.minY) }
    }
}

private struct SpikeTranscript: View {
    @Bindable var conversation: SpikeConversation
    let tracksPosition: Bool
    let followsEnd: Bool
    var positionAnchor: UnitPoint?

    var body: some View {
        let scroll = ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(conversation.rows) { row in
                    Text("\(row.id) " + String(repeating: "word ", count: row.words))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: {
                            conversation.frames[row.id] = $0
                        }
                        .onDisappear { conversation.frames[row.id] = nil }
                }
            }
            .scrollTargetLayout()
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { conversation.geometry = $1 }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followsEnd ? .bottom : nil, for: .sizeChanges)
        if tracksPosition {
            scroll.scrollPosition($conversation.position, anchor: positionAnchor)
        } else {
            scroll
        }
    }
}

@MainActor
private final class SpikeHost {
    let conversation: SpikeConversation
    #if canImport(AppKit)
    let window: NSWindow
    var view: NSView { window.contentView! }
    #else
    let window: UIWindow
    var view: UIView { window.rootViewController!.view }
    #endif

    init(_ conversation: SpikeConversation, tracksPosition: Bool, followsEnd: Bool = true,
         positionAnchor: UnitPoint? = nil, size: CGSize = CGSize(width: 500, height: 700)) {
        self.conversation = conversation
        let root = SpikeTranscript(conversation: conversation, tracksPosition: tracksPosition, followsEnd: followsEnd,
                                   positionAnchor: positionAnchor)
        #if canImport(AppKit)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        #else
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        #endif
    }

    func close() {
        #if canImport(AppKit)
        window.close()
        #else
        window.isHidden = true
        #endif
    }

    func resize(width: CGFloat) {
        #if canImport(AppKit)
        window.setContentSize(NSSize(width: width, height: window.frame.height))
        #else
        window.frame.size.width = width
        #endif
    }

    /// Scrolls the native scroll view up the way a reader's drag does, by a distance or to the top.
    func scrollUp(by distance: CGFloat) throws {
        #if canImport(AppKit)
        func find(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
        }
        let scroll = try #require(find(view))
        let clip = scroll.contentView
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(clip.bounds.minY - distance, -scroll.contentInsets.top)))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        #else
        func find(_ view: UIView) -> UIScrollView? {
            (view as? UIScrollView) ?? view.subviews.lazy.compactMap(find).first
        }
        let scroll = try #require(find(view))
        // A finger drag's delegate callbacks around the move, as the app's automation drives one.
        let inset = scroll.adjustedContentInset
        let bottom = max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.contentOffset.y = min(bottom, max(scroll.contentOffset.y - distance, -inset.top))
        var target = scroll.contentOffset
        scroll.delegate?.scrollViewWillEndDragging?(scroll, withVelocity: .zero, targetContentOffset: &target)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
        #endif
    }

    func wait(_ description: String, sourceLocation: SourceLocation = #_sourceLocation,
              _ condition: () -> Bool) async throws {
        try await waitUntil(description, in: view, sourceLocation: sourceLocation, condition)
    }

    /// Lets this many frames pass, returning the most a measurement moved from its first value.
    @discardableResult
    func watch(frames: Int = 20, _ measure: () -> CGFloat?) async throws -> (first: CGFloat?, last: CGFloat?, swing: CGFloat) {
        var count = 0
        var first: CGFloat?
        var last: CGFloat?
        var low = CGFloat.infinity
        var high = -CGFloat.infinity
        try await waitUntil(in: view) {
            let value = measure()
            if count == 0 { first = value }
            last = value
            if let value {
                low = min(low, value)
                high = max(high, value)
            }
            count += 1
            return count > frames
        }
        return (first, last, high >= low ? high - low : .nan)
    }

    func landAtTheEnd() async throws {
        try await wait("lands at the end") {
            conversation.contentHeight > view.bounds.height && abs(conversation.gapBelow) <= 1
                && !conversation.frames.isEmpty
        }
        try await watch(frames: 5) { conversation.gapBelow }
    }
}

private enum SpikeResults {
    static let platform: String = {
        #if os(macOS)
        "mac"
        #else
        "phone"
        #endif
    }()

    static func record(_ line: String) {
        let text = "\(platform)\t\(line)\n"
        print("SPIKE \(text)", terminator: "")
        let url = URL(fileURLWithPath: "/tmp/tbm-t1238-results.tsv")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

private func format(_ value: CGFloat?) -> String { value.map { String(format: "%.1f", $0) } ?? "none" }

@MainActor @Suite("t1238 platform scroll spike", .serialized)
struct PlatformScrollSpikeTests {
    enum Landing: String, CaseIterable { case midConversation, nearTheEnd }

    /// Opening at the New divider: the conversation's first layout puts the divider's row at the top.
    @Test func opensOnARowByIdentity() async throws {
        let conversation = SpikeConversation(ids: 0...299)
        conversation.position = ScrollPosition(id: 150, anchor: .top)
        let host = SpikeHost(conversation, tracksPosition: true)
        defer { host.close() }
        var checks = 0
        var sawOtherRows = false
        try await host.wait("shows row 150") {
            checks += 1
            if conversation.frames[150] == nil, !conversation.frames.isEmpty { sawOtherRows = true }
            return conversation.frames[150] != nil
        }
        let firstTop = conversation.frames[150]?.minY
        let watched = try await host.watch(frames: 30) { conversation.frames[150]?.minY }
        SpikeResults.record("open at 150\tfirst top \(format(firstTop)) after \(checks) checks, other rows first "
            + "\(sawOtherRows)\tsettled top \(format(watched.last))\tswing \(format(watched.swing))")
        #expect(abs(watched.last ?? .infinity) <= 1 && watched.swing <= 1 && !sawOtherRows)
    }

    /// A reveal or a New divider placement: the target row's top lands at the viewport's top and stays.
    @Test(arguments: Landing.allCases)
    func landsOnARowByIdentity(_ landing: Landing) async throws {
        let conversation = SpikeConversation(ids: 0...299)
        let host = SpikeHost(conversation, tracksPosition: true)
        defer { host.close() }
        try await host.landAtTheEnd()
        let target = landing == .midConversation ? 150 : 296
        conversation.position.scrollTo(id: target, anchor: .top)
        var checks = 0
        try await host.wait("shows row \(target)") {
            checks += 1
            return conversation.frames[target] != nil
        }
        let firstTop = conversation.frames[target]?.minY
        let watched = try await host.watch(frames: 30) { conversation.frames[target]?.minY }
        let gap = conversation.gapBelow
        SpikeResults.record("land \(landing.rawValue)\tfirst top \(format(firstTop)) after \(checks) checks"
            + "\tsettled top \(format(watched.last))\tswing \(format(watched.swing))\tgap below \(format(gap))")
        if landing == .midConversation {
            #expect(abs(watched.last ?? .infinity) <= 1)
        } else {
            #expect(abs(gap) <= 1)
        }
        #expect(watched.swing <= 1)
    }

    enum EndChange: String, CaseIterable { case arrival, lastGrows, lastShrinks }

    private func apply(_ change: EndChange, to conversation: SpikeConversation) {
        switch change {
        case .arrival:
            let id = conversation.rows.last!.id + 1
            conversation.rows.append(.init(id: id, words: 60))
        case .lastGrows: conversation.rows[conversation.rows.count - 1].words += 80
        case .lastShrinks: conversation.rows[conversation.rows.count - 1].words = 1
        }
    }

    /// Following the end: at the end, an arrival or the last row resizing keeps the end in view.
    @Test(arguments: EndChange.allCases, [false, true])
    func followsTheEndWithSizeChanges(_ change: EndChange, tracksPosition: Bool) async throws {
        let conversation = SpikeConversation(ids: 0...199)
        let host = SpikeHost(conversation, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        let before = conversation.contentHeight
        apply(change, to: conversation)
        try await host.wait("the content resizes") { abs(conversation.contentHeight - before) > 1 }
        let watched = try await host.watch { conversation.gapBelow }
        SpikeResults.record("end \(change.rawValue) position=\(tracksPosition)\tgap first \(format(watched.first))"
            + "\tsettled \(format(watched.last))\tswing \(format(watched.swing))")
        #expect(abs(watched.last ?? .infinity) <= 1)
    }

    /// A reader scrolled up keeps their place while the end changes below them.
    @Test(arguments: [EndChange.arrival, .lastGrows], [false, true])
    func keepsTheReadersPlaceWhenTheEndChanges(_ change: EndChange, tracksPosition: Bool) async throws {
        let conversation = SpikeConversation(ids: 0...199)
        let host = SpikeHost(conversation, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        try host.scrollUp(by: 2_000)
        try await host.wait("scrolled up") { conversation.gapBelow > 1_500 }
        try await host.watch(frames: 5) { conversation.topRow?.minY }
        let anchor = try #require(conversation.topRow)
        let before = conversation.contentHeight
        apply(change, to: conversation)
        try await host.wait("the content resizes") { abs(conversation.contentHeight - before) > 1 }
        let watched = try await host.watch { conversation.frames[anchor.id]?.minY }
        let moved = (watched.last ?? .nan) - anchor.minY
        SpikeResults.record("reading \(change.rawValue) position=\(tracksPosition)\tanchor \(anchor.id) moved "
            + "\(format(moved))\tswing \(format(watched.swing))\tposition id \(conversation.position.viewID(type: Int.self).map(String.init) ?? "none")")
        #expect(abs(moved) <= 1)
    }

    enum Reader: String, CaseIterable { case atTheTop, nearTheTop }

    /// Paging: older messages arrive above a reader at or near the top, and the reader's row stays put.
    @Test(arguments: Reader.allCases, [false, true])
    func keepsThePlaceWhenAnOlderPageArrives(_ reader: Reader, tracksPosition: Bool) async throws {
        let conversation = SpikeConversation(ids: 100...299)
        let host = SpikeHost(conversation, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        try host.scrollUp(by: 1_000_000)
        try await host.wait("reaches the top, at \(format(conversation.geometry?.contentOffset.y)) with inset "
                            + "\(format(conversation.geometry?.contentInsets.top)) showing \(conversation.topRow.map { "\($0.id)" } ?? "none")") {
            conversation.frames[100] != nil
                && (conversation.geometry?.contentOffset.y ?? 1) <= 1 - (conversation.geometry?.contentInsets.top ?? 0)
        }
        if reader == .nearTheTop {
            // Back down by a few rows, so the reader is reading rather than resting on the edge.
            try host.scrollUp(by: -600)
        }
        try await host.watch(frames: 5) { conversation.topRow?.minY }
        let anchor = try #require(conversation.topRow)
        let before = conversation.contentHeight
        conversation.rows.insert(contentsOf: (0...99).map { .init(id: $0, words: SpikeConversation.words(for: $0)) }, at: 0)
        try await host.wait("the page arrives") { conversation.contentHeight > before + 100 }
        let watched = try await host.watch { conversation.frames[anchor.id]?.minY }
        let moved = (watched.last ?? .nan) - anchor.minY
        SpikeResults.record("paging \(reader.rawValue) position=\(tracksPosition)\tanchor \(anchor.id) moved "
            + "\(format(moved))\tswing \(format(watched.swing))\ttop row now \(conversation.topRow.map { "\($0.id)" } ?? "none")")
        #expect(abs(moved) <= 1)
    }

    /// Rows above the reader change height, like an image loading, including the row cut by the top edge,
    /// and the reader's row below it stays put.
    @Test(arguments: [false, true])
    func keepsThePlaceWhenRowsAboveChangeHeight(tracksPosition: Bool) async throws {
        let conversation = SpikeConversation(ids: 0...199)
        let host = SpikeHost(conversation, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        try host.scrollUp(by: 2_050)
        try await host.wait("scrolled up") { conversation.gapBelow > 1_500 }
        try await host.watch(frames: 5) { conversation.topRow?.minY }
        let cut = try #require(conversation.topRow)
        let anchorID = cut.id + 1
        let anchor = try #require(conversation.frames[anchorID]?.minY)
        let cutHeight = try #require(conversation.frames[cut.id]?.height)
        let index = try #require(conversation.rows.firstIndex { $0.id == cut.id })
        for above in (index - 6)...index { conversation.rows[above].words += 60 }
        try await host.wait("the cut row grows, now \(format(conversation.frames[cut.id]?.height)) from \(format(cutHeight))") { (conversation.frames[cut.id]?.height ?? 0) > cutHeight + 20 }
        let watched = try await host.watch { conversation.frames[anchorID]?.minY }
        let moved = (watched.last ?? .nan) - anchor
        SpikeResults.record("above grows position=\(tracksPosition)\tcut row \(cut.id) at \(format(cut.minY)), anchor "
            + "\(anchorID) moved \(format(moved))\tswing \(format(watched.swing))")
        #expect(abs(moved) <= 1)
    }

    enum Place: String, CaseIterable { case atTheEnd, reading }

    /// The window narrows, rows rewrap and grow, and the reader keeps the end or their row.
    @Test(arguments: Place.allCases, [0, 1, 2])
    func keepsThePlaceWhenTheWidthChanges(_ place: Place, tracking: Int) async throws {
        let tracksPosition = tracking > 0
        let conversation = SpikeConversation(ids: 0...199)
        let host = SpikeHost(conversation, tracksPosition: tracksPosition, positionAnchor: tracking == 2 ? .top : nil)
        defer { host.close() }
        try await host.landAtTheEnd()
        if place == .reading {
            try host.scrollUp(by: 2_000)
            try await host.wait("scrolled up") { conversation.gapBelow > 1_500 }
        }
        try await host.watch(frames: 5) { conversation.topRow?.minY }
        let anchor = try #require(conversation.topRow)
        let before = conversation.contentHeight
        host.resize(width: 340)
        try await host.wait("rows rewrap") { conversation.contentHeight > before + 100 }
        let watched = try await host.watch { place == .atTheEnd ? conversation.gapBelow : conversation.frames[anchor.id]?.minY }
        let moved = place == .atTheEnd ? watched.last : (watched.last ?? .nan) - anchor.minY
        SpikeResults.record("width \(place.rawValue) position=\(["false", "true", "true anchor top"][tracking])\t"
            + (place == .atTheEnd ? "gap below" : "anchor \(anchor.id) from \(format(anchor.minY)) moved") + " \(format(moved))\tswing \(format(watched.swing))")
        #expect(abs(moved ?? .infinity) <= 1)
    }

    /// Scrolling up through rows the lazy stack only estimated moves the reader's row by exactly what was scrolled.
    @Test(arguments: [false, true])
    func scrollingUpThroughEstimatedRowsMovesByWhatWasScrolled(tracksPosition: Bool) async throws {
        let conversation = SpikeConversation(ids: 0...299)
        let host = SpikeHost(conversation, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        var worst: CGFloat = 0
        for _ in 0..<15 {
            let anchor = try #require(conversation.topRow)
            try host.scrollUp(by: 300)
            try await host.watch(frames: 3) { conversation.frames[anchor.id]?.minY }
            if let after = conversation.frames[anchor.id]?.minY {
                worst = max(worst, abs(after - anchor.minY - 300))
            }
        }
        SpikeResults.record("scroll up position=\(tracksPosition)\tworst error \(format(worst)) over 15 steps of 300")
        #expect(worst <= 1)
    }
}

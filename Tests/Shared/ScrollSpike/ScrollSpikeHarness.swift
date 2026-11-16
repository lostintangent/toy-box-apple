import Foundation
import ImageIO
import SwiftUI
import Testing
import ToyBoxClient
@testable import ToyBoxKit
import ToyBoxUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// t1238 spike, round 2: plain SwiftUI scrolling around each app's real message rows. This one file
// is linked into both apps' test targets, and each supplies only how its rows draw.

/// history-demo's 480 messages, as `scripts/demo-server/channels/history-channel.ts` builds them,
/// plus a member joining every 50th message, a 40-message run from the lead, and one image.
enum SpikeFixture {
    static let run = 300...339
    static let imageSequence = 360
    static let agents: [ChannelAgent] = [
        .lead(id: "lead", profile: .init(name: "Lead", role: "Coordinator.",
                                         avatar: .init(mark: "M4 12H20", color: "#123456"))),
        ChannelAgent(id: "pixel", name: "Pixel", role: "Designer"),
        ChannelAgent(id: "forge", name: "Forge", role: "Builder"),
        ChannelAgent(id: "scout", name: "Scout", role: "Researcher"),
    ]

    static func id(_ sequence: Int) -> String { "history-message-\(sequence)" }

    static func messages(_ sequences: ClosedRange<Int>, imageURL: String? = nil) -> [ChannelMessage] {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        return sequences.map { sequence in
            let timestamp = now.addingTimeInterval(TimeInterval(sequence - 480) * 20 * 60).formatted(.iso8601)
            if sequence.isMultiple(of: 50), !run.contains(sequence) {
                return ChannelMessage(id: id(sequence), sequence: sequence, timestamp: timestamp, sender: .system,
                                      content: .system(.init(type: "member_joined",
                                                             member: agents[sequence / 50 % 3 + 1])))
            }
            let sender: ChannelMessageSender = run.contains(sequence) ? .agent("lead")
                : sequence.isMultiple(of: 9) ? .user : .agent(agents[sequence % agents.count].id)
            let text = sequence.isMultiple(of: 17)
                ? "History message \(sequence)\n\nA measured checkpoint for paging.\n\n- Preserve the visible row\n"
                    + "- Keep read receipts monotonic\n- Leave requests unanswered by reads"
                : "History message \(sequence): the workshop keeps older decisions available while the team "
                    + "continues its current work."
            var message = ChannelMessage(id: id(sequence), sequence: sequence, timestamp: timestamp, sender: sender,
                                         content: .text(text))
            if sequence == imageSequence, let imageURL {
                message.content = .text("History message \(sequence): here's the screenshot.")
                message.attachments = [ChannelAttachment(name: "late.png", url: imageURL, mimeType: "image/png")]
            }
            return message
        }
    }

    /// The row builder's rows with every agent run split into one row per message, as the phone's
    /// items do and t1233 proposes for the Mac, each with the gap above it.
    static func split(_ rows: [TranscriptRow]) -> [(row: TranscriptRow, spacing: CGFloat)] {
        var split: [(row: TranscriptRow, spacing: CGFloat)] = []
        var previous: TranscriptRow?
        for row in rows {
            let gap = previous.map { TranscriptSpacing.between($0, row) } ?? 0
            if case .agent(let agentId, let entries) = row.content {
                for (index, entry) in entries.enumerated() {
                    split.append((TranscriptRow(id: entry.id, content: .agent(agentId: agentId, entries: [entry]),
                                                divider: index == 0 ? row.divider : nil),
                                  index == 0 ? gap : TranscriptSpacing.entry))
                }
            } else {
                split.append((row, gap))
            }
            previous = row
        }
        return split
    }
}

/// Serves `/spike-image/...` with a 600 by 900 PNG. One whose path has `held` waits for `release()`.
final class SpikeImageProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [SpikeImageProtocol] = []
    nonisolated(unsafe) private static var registered = false

    static func register() {
        lock.withLock {
            if !registered { URLProtocol.registerClass(SpikeImageProtocol.self) }
            registered = true
        }
    }

    static var heldCount: Int { lock.withLock { held.count } }

    static func release() {
        let requests = lock.withLock { defer { held = [] }; return held }
        for request in requests { request.respond() }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/spike-image/") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path.contains("held") == true {
            Self.lock.withLock { Self.held.append(self) }
        } else {
            respond()
        }
    }

    override func stopLoading() {}

    private func respond() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "image/png"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static let png: Data = {
        let context = CGContext(data: nil, width: 600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()
}

@MainActor @Observable
final class SpikeChannel {
    var messages: [ChannelMessage]
    var unreadAfter: Int?
    let store: ChannelStore
    let interaction = ChannelInteraction()
    var position = ScrollPosition(idType: String.self)
    var frames: [String: CGRect] = [:]
    var geometry: ScrollGeometry?
    /// The reader's row, which a width change scrolls back to once when it's set.
    var readerID: String?
    /// Whether the scroll view starts at the end, as the apps do unless they open on a row.
    var opensAtTheEnd = true
    /// Whether size changes keep the end in place, as following the end needs.
    var sizeChangesKeepTheEnd = true
    /// Grows a stand-in row from 90 to 160 points tall, as a remote image's placeholder does.
    var grown = false
    @ObservationIgnored private let builder = TranscriptRowBuilder()

    init(_ messages: [ChannelMessage], unreadAfter: Int? = nil) throws {
        self.messages = messages
        self.unreadAfter = unreadAfter
        store = ChannelStore(id: "spike", api: try ChannelAPI(serverURL: "https://spike.invalid"))
    }

    var rows: [TranscriptRow] {
        builder.rows(messages, lead: SpikeFixture.agents[0], members: Array(SpikeFixture.agents.dropFirst()),
                     unreadAfter: unreadAfter)
    }

    var gapBelow: CGFloat {
        guard let geometry else { return .nan }
        return geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
    }
    var contentHeight: CGFloat { geometry?.contentSize.height ?? 0 }
    var isAtTop: Bool {
        guard let geometry else { return false }
        return geometry.contentOffset.y <= 1 - geometry.contentInsets.top
    }
    var topRow: (id: String, minY: CGFloat)? {
        frames.filter { $0.value.maxY > 0 }.min { $0.value.minY < $1.value.minY }.map { ($0.key, $0.value.minY) }
    }
}

/// What stands in for the image row, to find which part of it the platform misplaces.
enum SpikeGrower: String, CaseIterable {
    /// A tile under the row's text, as a plain rectangle.
    case plain
    /// The same tile in a plain button, as the image tile is.
    case button
    /// The same tile in the attachment strip's horizontal scroll view.
    case strip
    /// The strip's tile grows from its own state, set in a task after a suspension, as a load does.
    case task
    /// That, and the tile's content swaps from a spinner to an image as it grows.
    case swap
    /// A spinner goes away as it grows.
    case spinnerGoes
    /// An image appears as it grows.
    case imageAppears
    /// One color gives way to another through an if-else branch as it grows.
    case branch
    /// The spinner stays while it grows.
    case spinnerStays
    /// An image appears with no transition as it grows.
    case identityTransition
    /// An image that was always there turns opaque as it grows.
    case opacity
    /// An image appears and the tile keeps its height.
    case insertOnly
    /// The tile grows, and an image appears in a later update.
    case insertLater
}

private struct SpikeGrowerRow: View {
    let channel: SpikeChannel
    let grower: SpikeGrower
    @ViewState private var loaded = false
    @ViewState private var inserted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History message \(SpikeFixture.imageSequence): here's the screenshot.")
            switch grower {
            case .plain: tile
            case .button: Button {} label: { tile }.buttonStyle(.plain)
            default:
                TranscriptAttachmentStrip(count: 1, alignment: .leading, presented: nil) { _ in tile }
            }
        }
        .task(id: channel.grown) {
            guard channel.grown, ![.plain, .button, .strip].contains(grower) else { return }
            await Task.yield()
            loaded = true
            if grower == .insertLater { await Task.yield() }
            inserted = true
        }
        .padding(.top, 20)
        .padding(.horizontal, 20)
    }

    private var grown: Bool {
        grower == .insertOnly ? false : [.plain, .button, .strip].contains(grower) ? channel.grown : loaded
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.blue)
            switch grower {
            case .swap:
                if grown { Image(systemName: "photo").resizable().scaledToFit() } else { ProgressView() }
            case .spinnerGoes:
                if !grown { ProgressView() }
            case .imageAppears:
                if grown { Image(systemName: "photo").resizable().scaledToFit() }
            case .branch:
                if grown { Color.green.padding(8) } else { Color.red.padding(8) }
            case .spinnerStays:
                ProgressView()
            case .identityTransition:
                if grown { Image(systemName: "photo").resizable().scaledToFit().transition(.identity) }
            case .opacity:
                Image(systemName: "photo").resizable().scaledToFit().opacity(grown ? 1 : 0)
            case .insertOnly, .insertLater:
                if inserted { Image(systemName: "photo").resizable().scaledToFit() }
            default:
                EmptyView()
            }
        }
        .frame(width: 120, height: grown ? 160 : 90)
    }
}

struct SpikeItem: Identifiable {
    let id: String
    let view: AnyView
}

private struct SpikeTranscript: View {
    @Bindable var channel: SpikeChannel
    let tracksPosition: Bool
    let items: @MainActor (SpikeChannel) -> [SpikeItem]

    var body: some View {
        let scroll = ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items(channel)) { item in
                    item.view
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: {
                            channel.frames[item.id] = $0
                        }
                        .onDisappear { channel.frames[item.id] = nil }
                }
            }
            .padding(.vertical, 12)
            .scrollTargetLayout()
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
            channel.geometry = new
            if abs(old.containerSize.width - new.containerSize.width) >= 0.5, let reader = channel.readerID {
                channel.position.scrollTo(id: reader, anchor: .top)
            }
        }
        .defaultScrollAnchor(channel.opensAtTheEnd ? .bottom : nil, for: .initialOffset)
        .defaultScrollAnchor(channel.sizeChangesKeepTheEnd ? .bottom : nil, for: .sizeChanges)
        .environment(channel.interaction)
        if tracksPosition {
            scroll.scrollPosition($channel.position)
        } else {
            scroll
        }
    }
}

@MainActor
final class SpikeHost {
    let channel: SpikeChannel
    let tracksPosition: Bool
    #if canImport(AppKit)
    let window: NSWindow
    var view: NSView { window.contentView! }
    #else
    let window: UIWindow
    var view: UIView { window.rootViewController!.view }
    #endif

    init(_ channel: SpikeChannel, tracksPosition: Bool = true, size: CGSize,
         items: @escaping @MainActor (SpikeChannel) -> [SpikeItem]) {
        self.channel = channel
        self.tracksPosition = tracksPosition
        SpikeImageProtocol.register()
        let root = SpikeTranscript(channel: channel, tracksPosition: tracksPosition, items: items)
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

    /// Scrolls the native scroll view up the way a reader does, by a distance or to the top. A negative
    /// distance scrolls down.
    func scrollUp(by distance: CGFloat) throws {
        #if canImport(AppKit)
        func find(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
        }
        let scroll = try #require(find(view))
        let clip = scroll.contentView
        let bottom = (scroll.documentView?.bounds.height ?? 0) + scroll.contentInsets.bottom - clip.bounds.height
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: NSPoint(x: clip.bounds.minX,
                                y: min(bottom, max(clip.bounds.minY - distance, -scroll.contentInsets.top))))
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

    func wait(_ description: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation,
              _ condition: () -> Bool) async throws {
        try await waitUntil(description(), in: view, sourceLocation: sourceLocation, condition)
    }

    /// Lets this many frames pass, returning the first and last measurement and the most it moved.
    @discardableResult
    func watch(frames: Int = 20, _ measure: () -> CGFloat?) async throws
        -> (first: CGFloat?, last: CGFloat?, swing: CGFloat) {
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
        try await wait("lands at the end, \(spikeFormat(channel.gapBelow)) above it") {
            channel.contentHeight > view.bounds.height && abs(channel.gapBelow) <= 1 && !channel.frames.isEmpty
        }
        try await watch(frames: 5) { channel.gapBelow }
    }

    /// Puts a row's top at the viewport's top and waits for it to settle there.
    func place(_ id: String) async throws {
        if tracksPosition {
            channel.position.scrollTo(id: id, anchor: .top)
        } else {
            for _ in 0..<200 where channel.frames[id] == nil {
                try scrollUp(by: 300)
                try await watch(frames: 2) { channel.frames[id]?.minY }
            }
            try scrollUp(by: -(channel.frames[id]?.minY ?? 0))
        }
        try await wait("places \(id), at \(spikeFormat(channel.frames[id]?.minY))") {
            channel.frames[id].map { abs($0.minY) <= 1 } == true
        }
        try await watch(frames: 5) { channel.frames[id]?.minY }
    }
}

enum SpikeResults {
    static func record(_ line: String) {
        #if os(macOS)
        let platform = "mac"
        #else
        let platform = "phone"
        #endif
        let text = "\(platform) real\t\(line)\n"
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

func spikeFormat(_ value: CGFloat?) -> String { value.map { String(format: "%.1f", $0) } ?? "none" }

/// The cases, each on a channel of history-demo's real messages. Each app's suite calls these with
/// its own rows.
@MainActor
struct SpikeCases {
    let size: CGSize
    let items: @MainActor (SpikeChannel) -> [SpikeItem]

    private func host(_ channel: SpikeChannel, tracksPosition: Bool = true) -> SpikeHost {
        SpikeHost(channel, tracksPosition: tracksPosition, size: size, items: items)
    }

    /// Opening loads the latest 100 and lands on the New divider at 451.
    func opensOnTheNewDivider(opensAtTheEnd: Bool) async throws {
        let channel = try SpikeChannel(SpikeFixture.messages(381...480), unreadAfter: 450)
        channel.opensAtTheEnd = opensAtTheEnd
        let target = SpikeFixture.id(451)
        channel.position = ScrollPosition(id: target, anchor: .top)
        let host = host(channel)
        defer { host.close() }
        var checks = 0
        var sawOtherRows = false
        try await host.wait("shows the New divider's row") {
            checks += 1
            if channel.frames[target] == nil, !channel.frames.isEmpty { sawOtherRows = true }
            return channel.frames[target] != nil
        }
        let first = channel.frames[target]?.minY
        let watched = try await host.watch(frames: 30) { channel.frames[target]?.minY }
        SpikeResults.record("open on New initialOffset=\(opensAtTheEnd ? "bottom" : "nil")\tfirst top \(spikeFormat(first)) after \(checks) checks, other rows first "
            + "\(sawOtherRows)\tsettled top \(spikeFormat(watched.last))\tswing \(spikeFormat(watched.swing))")
        #expect(abs(watched.last ?? .infinity) <= 1 && watched.swing <= 1 && !sawOtherRows)
    }

    enum Reveal: String, CaseIterable { case midConversation, insideTheRun, nearTheEnd }

    func reveals(_ reveal: Reveal) async throws {
        let channel = try SpikeChannel(SpikeFixture.messages(281...480))
        let host = host(channel)
        defer { host.close() }
        try await host.landAtTheEnd()
        let sequence = switch reveal {
        case .midConversation: 290
        case .insideTheRun: 320
        case .nearTheEnd: 478
        }
        let target = SpikeFixture.id(sequence)
        channel.position.scrollTo(id: target, anchor: .top)
        var checks = 0
        try await host.wait("shows \(target)") {
            checks += 1
            return channel.frames[target] != nil
        }
        let first = channel.frames[target]?.minY
        let watched = try await host.watch(frames: 30) { channel.frames[target]?.minY }
        SpikeResults.record("reveal \(reveal.rawValue) (\(sequence))\tfirst top \(spikeFormat(first)) after "
            + "\(checks) checks\tsettled top \(spikeFormat(watched.last))\tswing \(spikeFormat(watched.swing))"
            + "\tgap below \(spikeFormat(channel.gapBelow))")
        if reveal == .nearTheEnd {
            #expect(abs(channel.gapBelow) <= 1)
        } else {
            #expect(abs(watched.last ?? .infinity) <= 1)
        }
        #expect(watched.swing <= 1)
    }

    enum EndChange: String, CaseIterable { case arrival, lastGrows, lastShrinks }

    private func apply(_ change: EndChange, to channel: SpikeChannel) {
        let last = channel.messages.count - 1
        switch change {
        case .arrival:
            let sequence = channel.messages[last].sequence + 1
            channel.messages.append(ChannelMessage(
                id: SpikeFixture.id(sequence), sequence: sequence, timestamp: channel.messages[last].timestamp,
                sender: .agent("pixel"),
                content: .text("A new arrival with enough words to wrap across a couple of lines in the row.")))
        case .lastGrows:
            channel.messages[last].content = .text(channel.messages[last].text
                + "\n\n- One more point\n- And another\n\nWith a closing paragraph that wraps across the row.")
        case .lastShrinks:
            channel.messages[last].content = .text("Short.")
        }
    }

    func followsTheEnd(_ change: EndChange, tracksPosition: Bool) async throws {
        var messages = SpikeFixture.messages(281...479)
        if change == .lastShrinks {
            messages[messages.count - 1].content = .text(String(repeating: "A long last message. ", count: 30))
        }
        let channel = try SpikeChannel(messages)
        let host = host(channel, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        let before = channel.contentHeight
        apply(change, to: channel)
        try await host.wait("the content resizes") { abs(channel.contentHeight - before) > 1 }
        let watched = try await host.watch { channel.gapBelow }
        SpikeResults.record("end \(change.rawValue) position=\(tracksPosition)\tgap first "
            + "\(spikeFormat(watched.first))\tsettled \(spikeFormat(watched.last))\tswing \(spikeFormat(watched.swing))")
        #expect(abs(watched.last ?? .infinity) <= 1)
    }

    func keepsTheReadersPlaceWhenTheEndChanges(_ change: EndChange, tracksPosition: Bool) async throws {
        let channel = try SpikeChannel(SpikeFixture.messages(281...479))
        let host = host(channel, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        try host.scrollUp(by: 2_000)
        try await host.wait("scrolled up") { channel.gapBelow > 1_500 }
        try await host.watch(frames: 5) { channel.topRow?.minY }
        let anchor = try #require(channel.topRow)
        let before = channel.contentHeight
        apply(change, to: channel)
        try await host.wait("the content resizes") { abs(channel.contentHeight - before) > 1 }
        let watched = try await host.watch { channel.frames[anchor.id]?.minY }
        let moved = (watched.last ?? .nan) - anchor.minY
        SpikeResults.record("reading \(change.rawValue) position=\(tracksPosition)\tanchor \(anchor.id) moved "
            + "\(spikeFormat(moved))\tswing \(spikeFormat(watched.swing))")
        #expect(abs(moved) <= 1)
    }

    enum Reader: String, CaseIterable { case atTheTop, nearTheTop }

    /// A 100-message older page arrives while the reader is at or near the top.
    func keepsThePlaceWhenAnOlderPageArrives(_ reader: Reader, tracksPosition: Bool) async throws {
        let channel = try SpikeChannel(SpikeFixture.messages(381...480))
        let host = host(channel, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        try host.scrollUp(by: 1_000_000)
        try await host.wait("reaches the top") { channel.isAtTop && channel.frames[SpikeFixture.id(381)] != nil }
        if reader == .nearTheTop { try host.scrollUp(by: -600) }
        try await host.watch(frames: 5) { channel.topRow?.minY }
        let anchor = try #require(channel.topRow)
        let before = channel.contentHeight
        channel.messages.insert(contentsOf: SpikeFixture.messages(281...380), at: 0)
        try await host.wait("the page arrives") { channel.contentHeight > before + 100 }
        let watched = try await host.watch { channel.frames[anchor.id]?.minY }
        let moved = (watched.last ?? .nan) - anchor.minY
        SpikeResults.record("paging \(reader.rawValue) position=\(tracksPosition)\tanchor \(anchor.id) moved "
            + "\(spikeFormat(moved))\tswing \(spikeFormat(watched.swing))\ttop row now \(channel.topRow?.id ?? "none")")
        #expect(abs(moved) <= 1)
    }

    enum Cut: String, CaseIterable { case mostlyAbove, slightlyAbove }

    /// The image at 360 is cut by the top edge when its height arrives: mostly above, with only its
    /// last 20 points showing, or slightly, with 40 points above.
    func keepsThePlaceWhenAnImageAboveLoads(_ cut: Cut, tracksPosition: Bool, sizeChangesKeepTheEnd: Bool = true)
        async throws {
        let url = "/spike-image/held-\(UUID().uuidString).png"
        let channel = try SpikeChannel(SpikeFixture.messages(281...480, imageURL: url))
        channel.sizeChangesKeepTheEnd = sizeChangesKeepTheEnd
        let host = host(channel, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        let image = SpikeFixture.id(SpikeFixture.imageSequence)
        try await host.place(image)
        try await host.wait("the image is requested") { SpikeImageProtocol.heldCount > 0 }
        let height = try #require(channel.frames[image]?.height)
        try host.scrollUp(by: cut == .mostlyAbove ? -(height - 20) : -40)
        try await host.watch(frames: 5) { channel.topRow?.minY }
        let reader = SpikeFixture.id(SpikeFixture.imageSequence + 1)
        let anchor = try #require(channel.frames[reader]?.minY)
        let imageTop = channel.frames[image]?.minY
        let tracked = channel.position.viewID(type: String.self)
        let offset = channel.geometry?.contentOffset.y ?? .nan
        let content = channel.contentHeight
        var heights: [String] = []
        SpikeImageProtocol.release()
        let watched = try await host.watch(frames: 90) {
            let height = spikeFormat(channel.frames[image]?.height)
            if heights.last != height { heights.append(height) }
            return channel.frames[reader]?.minY
        }
        let moved = (watched.last ?? .nan) - anchor
        SpikeResults.record("image \(cut.rawValue) position=\(tracksPosition) sizeChanges="
            + "\(sizeChangesKeepTheEnd ? "bottom" : "nil")\timage row top \(spikeFormat(imageTop)), "
            + "heights \(spikeFormat(height)) then \(heights.joined(separator: ", ")), tracked \(tracked ?? "none")"
            + "\treader moved \(spikeFormat(moved))\tswing \(spikeFormat(watched.swing))\toffset +"
            + "\(spikeFormat((channel.geometry?.contentOffset.y ?? .nan) - offset)), content +"
            + spikeFormat(channel.contentHeight - content))
        #expect(abs(moved) <= 1)
    }

    /// The image case with a stand-in row that grows from 90 to 160 when the test says.
    func keepsThePlaceWhenAStandInAboveGrows(_ grower: SpikeGrower, cut: Cut, tracksPosition: Bool) async throws {
        let channel = try SpikeChannel(SpikeFixture.messages(281...480))
        let image = SpikeFixture.id(SpikeFixture.imageSequence)
        let host = SpikeHost(channel, tracksPosition: tracksPosition, size: size) { channel in
            items(channel).map { item in
                item.id == image ? SpikeItem(id: item.id, view: AnyView(SpikeGrowerRow(channel: channel, grower: grower)))
                    : item
            }
        }
        defer { host.close() }
        try await host.landAtTheEnd()
        try await host.place(image)
        let height = try #require(channel.frames[image]?.height)
        try host.scrollUp(by: cut == .mostlyAbove ? -(height - 20) : -40)
        try await host.watch(frames: 5) { channel.topRow?.minY }
        let reader = SpikeFixture.id(SpikeFixture.imageSequence + 1)
        let anchor = try #require(channel.frames[reader]?.minY)
        let imageTop = channel.frames[image]?.minY
        let tracked = channel.position.viewID(type: String.self)
        let offset = channel.geometry?.contentOffset.y ?? .nan
        let content = channel.contentHeight
        channel.grown = true
        let watched = try await host.watch(frames: 30) { channel.frames[reader]?.minY }
        let moved = (watched.last ?? .nan) - anchor
        let geometryChange = "offset +\(spikeFormat((channel.geometry?.contentOffset.y ?? .nan) - offset)), content +"
            + spikeFormat(channel.contentHeight - content)
        SpikeResults.record("stand-in \(grower.rawValue) \(cut.rawValue) position=\(tracksPosition)\trow top "
            + "\(spikeFormat(imageTop)) of \(spikeFormat(height)), tracked \(tracked ?? "none")\treader moved "
            + "\(spikeFormat(moved))\tswing \(spikeFormat(watched.swing))\t\(geometryChange)")
        #expect(abs(moved) <= 1)
    }

    enum Place: String, CaseIterable { case atTheEnd, reading }

    /// The width narrows, rows rewrap, and the reader keeps the end or their row. `restores` scrolls
    /// once back to the reader's row on a width change.
    func keepsThePlaceWhenTheWidthChanges(_ place: Place, tracksPosition: Bool, restores: Bool) async throws {
        let channel = try SpikeChannel(SpikeFixture.messages(281...480))
        let host = host(channel, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        let reader = SpikeFixture.id(420)
        if place == .reading { try await host.place(reader) }
        if restores { channel.readerID = reader }
        let tracked = channel.position.viewID(type: String.self)
        let before = channel.contentHeight
        let anchor = channel.frames[reader]?.minY
        host.resize(width: size.width * 0.65)
        try await host.wait("rows rewrap") { channel.contentHeight > before + 100 }
        let watched = try await host.watch { place == .atTheEnd ? channel.gapBelow : channel.frames[reader]?.minY }
        let moved = place == .atTheEnd ? watched.last : (watched.last ?? .nan) - (anchor ?? .nan)
        SpikeResults.record("width \(place.rawValue) position=\(tracksPosition) restores=\(restores)\t"
            + (place == .atTheEnd ? "gap below" : "\(reader) moved")
            + " \(spikeFormat(moved))\tswing \(spikeFormat(watched.swing))\ttracked \(tracked ?? "none")"
            + "\tnow \(channel.position.viewID(type: String.self) ?? "none")")
        #expect(abs(moved ?? .infinity) <= 1)
    }

    /// Scrolling up through rows the lazy stack only estimated moves the reader's row by exactly what
    /// was scrolled.
    func scrollingUpMovesByWhatWasScrolled(tracksPosition: Bool) async throws {
        let channel = try SpikeChannel(SpikeFixture.messages(181...480))
        let host = host(channel, tracksPosition: tracksPosition)
        defer { host.close() }
        try await host.landAtTheEnd()
        var worst: CGFloat = 0
        for _ in 0..<20 {
            let anchor = try #require(channel.topRow)
            try host.scrollUp(by: 300)
            try await host.watch(frames: 3) { channel.frames[anchor.id]?.minY }
            if let after = channel.frames[anchor.id]?.minY {
                worst = max(worst, abs(after - anchor.minY - 300))
            }
        }
        SpikeResults.record("scroll up position=\(tracksPosition)\tworst error \(spikeFormat(worst)) over 20 steps of 300")
        #expect(worst <= 1)
    }
}

/// Every case in one place, so each app's suite only names its rows.
@MainActor
func runAllSpikeCases(_ cases: SpikeCases, only: String? = ProcessInfo.processInfo.environment["SPIKE_ONLY"])
    async throws {
    func run(_ name: String, _ body: () async throws -> Void) async {
        if let only, !only.split(separator: ",").contains(where: { name == $0 }) { return }
        do { try await body() } catch { SpikeResults.record("\(name)\tthrew \(error)") }
    }
    for opensAtTheEnd in [true, false] {
        await run("open") { try await cases.opensOnTheNewDivider(opensAtTheEnd: opensAtTheEnd) }
    }
    for reveal in SpikeCases.Reveal.allCases {
        await run("reveal") { try await cases.reveals(reveal) }
    }
    for tracks in [true, false] {
        for change in SpikeCases.EndChange.allCases {
            await run("end") { try await cases.followsTheEnd(change, tracksPosition: tracks) }
            await run("reading") { try await cases.keepsTheReadersPlaceWhenTheEndChanges(change, tracksPosition: tracks) }
        }
        for reader in SpikeCases.Reader.allCases {
            await run("paging") { try await cases.keepsThePlaceWhenAnOlderPageArrives(reader, tracksPosition: tracks) }
        }
        for cut in SpikeCases.Cut.allCases {
            for keeps in [true, false] where tracks || keeps {
                await run("image") {
                    try await cases.keepsThePlaceWhenAnImageAboveLoads(cut, tracksPosition: tracks,
                                                                       sizeChangesKeepTheEnd: keeps)
                }
            }
        }
        for grower in SpikeGrower.allCases {
            for cut in SpikeCases.Cut.allCases where tracks && cut == .mostlyAbove {
                await run("stand-in") {
                    try await cases.keepsThePlaceWhenAStandInAboveGrows(grower, cut: cut, tracksPosition: tracks)
                }
            }
        }
        await run("scroll") { try await cases.scrollingUpMovesByWhatWasScrolled(tracksPosition: tracks) }
        for place in SpikeCases.Place.allCases {
            for restores in [false, true] where !(restores && place == .atTheEnd) {
                await run("width") {
                    try await cases.keepsThePlaceWhenTheWidthChanges(place, tracksPosition: tracks, restores: restores)
                }
            }
        }
    }
}

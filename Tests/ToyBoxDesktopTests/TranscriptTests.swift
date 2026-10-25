import AppKit
import ChannelClient
import ChannelIntelligence
import ChannelKit
import Foundation
import ImageIO
import SwiftUI
import Synchronization
import Testing
import UniformTypeIdentifiers
import VisionKit
@testable import ToyBoxDesktop

private let transcriptTimingTestsEnabled = ProcessInfo.processInfo.environment["TOY_BOX_TEST_TRANSCRIPT_TIMING"] == "1"

@MainActor
@Suite("Explicit transcript table heights", .serialized)
struct TranscriptTableHeightTests {
    @Test func cancelledSnapshotPublicationsDoNotLoseTheFinalVisibleSequence() async {
        let state = TranscriptDocumentState()
        let first = TranscriptDocumentState.Snapshot(hasLanded: true, isAtBottom: false, visibleSequence: 10)
        let last = TranscriptDocumentState.Snapshot(hasLanded: true, isAtBottom: false, visibleSequence: 20)

        let cancelled = state.publish(first)
        state.cancelPublication()
        await cancelled?.value
        #expect(state.snapshot == .init())
        await state.publish(first)?.value
        #expect(state.snapshot == first)

        let superseded = state.publish(last)
        await state.publish(first)?.value
        await superseded?.value
        #expect(state.snapshot == first)

        state.publish(last)
        state.publish(first)
        await state.publish(last)?.value
        #expect(state.snapshot == last)
    }

    @Test func tableItemsKeepCanonicalRunEntriesAndOnlyTheFirstAvatar() {
        let lead = ChannelAgent.lead(id: "lead")
        let messages = (1...5).map(transcriptTestMessage)
        let rows = transcriptRows(messages, lead: lead, members: [])
        let items = TranscriptTableItem.project(rows)
        let canonical = rows.flatMap { row -> [AgentRunEntry] in
            if case .agent(_, let entries) = row.content { return entries }
            return []
        }
        let flattened = items.flatMap { item -> [AgentRunEntry] in
            if case .agent(_, let entries) = item.row.content { return entries }
            return []
        }
        #expect(flattened == canonical)
        #expect(items.flatMap(\.row.messages) == messages)
        #expect(items.map(\.id) == messages.map(\.id))
        #expect(items.map(\.showsAvatar) == [true, false, false, false, false])
        #expect(items.map(\.topSpacing) == [20, 8, 8, 8, 8])
        #expect(items.dropFirst().allSatisfy { $0.row.divider == nil })
    }

    @Test func tableHeightsAreExactWidthDependentAndCachedByContent() throws {
        let setup = try setup()
        var messages = (1...2).map(transcriptTestMessage)
        messages[1].content = .text(String(repeating: "A longer paragraph that must wrap at this exact width. ", count: 25))
        let items = TranscriptTableItem.project(transcriptRows(messages, lead: setup.lead, members: []))
        let content = content(items, setup: setup)
        let cache = TranscriptTableHeights()
        let wide = cache.resolve(items: items, content: content, width: 720, environment: setup.environment)
        let narrow = cache.resolve(items: items, content: content, width: 420, environment: setup.environment)
        let again = cache.resolve(items: items, content: content, width: 720, environment: setup.environment)
        #expect(wide.measured == 2 && narrow.measured == 2 && again.measured == 0)
        #expect(wide.heights == again.heights)
        #expect(narrow.heights[1] > wide.heights[1])
        #expect(wide.heights[1] > wide.heights[0])
        messages[1].content = .text("Changed.")
        let changedItems = TranscriptTableItem.project(transcriptRows(messages, lead: setup.lead, members: []))
        let changed = self.content(changedItems, setup: setup)
        let updated = cache.resolve(items: changedItems, content: changed, width: 720,
                                    environment: setup.environment)
        #expect(updated.measured == 1)
    }

    @Test func emptyAndVisibleAccessoriesKeepTheirMeasurementSlots() throws {
        let setup = try setup()
        let cache = TranscriptTableHeights()
        #expect(cache.measureAccessory(AnyView(EmptyView()), width: 600, environment: setup.environment) == 0)
        #expect(cache.measureAccessory(AnyView(Color.clear.frame(height: 40)), width: 600,
                                       environment: setup.environment) == 40)
    }

    @Test func boundedHeightMeasurementLeavesExplicitEstimatesOutsideTheRequestedRows() throws {
        let setup = try setup()
        let items = TranscriptTableItem.project(transcriptRows((1...100).map(transcriptTestMessage),
                                                               lead: setup.lead, members: []))
        let content = content(items, setup: setup)
        let cache = TranscriptTableHeights()
        let tail = IndexSet(90..<100)
        let initial = cache.resolve(items: items, content: content, width: 720,
                                    environment: setup.environment, measuring: tail)
        #expect(initial.measured == 10)
        #expect(initial.exactIndexes == tail)
        #expect(initial.heights.count == 100 && initial.heights.allSatisfy { $0 > 0 && $0.isFinite })
        let warm = cache.resolve(items: items, content: content, width: 720,
                                 environment: setup.environment, measuring: tail)
        #expect(warm.measured == 0 && warm.heights == initial.heights)
        let head = IndexSet(0..<10)
        let front = cache.resolve(items: items, content: content, width: 720,
                                  environment: setup.environment, measuring: head)
        #expect(front.measured == 10 && front.exactIndexes == tail.union(head))
        #expect(Array(front.heights[90..<100]) == Array(initial.heights[90..<100]))
        let narrow = cache.resolve(items: items, content: content, width: 420,
                                   environment: setup.environment, measuring: tail)
        #expect(narrow.measured == 10 && narrow.exactIndexes == tail)
        #expect(cache.measurementCount == 30)
    }

    @Test func liveHostMeasurementsKeepTheirExactContentAndEnvironmentIdentity() throws {
        let setup = try setup()
        let items = TranscriptTableItem.project(transcriptRows((1...5).map(transcriptTestMessage),
                                                               lead: setup.lead, members: []))
        let content = content(items, setup: setup)
        let cache = TranscriptTableHeights()
        cache.recordLiveHeight(320, item: items[3], content: content[3], width: 720,
                               environment: setup.environment, overflows: nil)
        let live = cache.resolve(items: items, content: content, width: 720,
                                 environment: setup.environment, measuring: IndexSet())
        #expect(live.exactIndexes == IndexSet(integer: 3))
        #expect(live.heights[3] == 320 && live.measured == 0)
        let changedWidth = cache.resolve(items: items, content: content, width: 420,
                                         environment: setup.environment, measuring: IndexSet())
        #expect(changedWidth.exactIndexes.isEmpty && changedWidth.heights[3] == 320)
        let measured = cache.resolve(items: items, content: content, width: 420,
                                     environment: setup.environment, measuring: IndexSet(integer: 3))
        #expect(measured.measured == 1 && measured.heights[3] != 320)
    }

    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func liveHostingInvalidatesItsIntrinsicHeightWhenOnlyMountedStateChanges() async throws {
        let data = HostedHeight()
        let host = TranscriptTableHostingView(rootView: AnyView(HostedHeightFixture(data: data)))
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: -6_000, y: -6_000, width: 300, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await transcriptUntil(in: host) { host.intrinsicContentSize.height == 80 }
        var invalidations = 0
        host.onHeightInvalidated = { invalidations += 1 }
        for height: CGFloat in [160, 48, 240, 80] {
            let previous = invalidations
            data.height = height
            try await transcriptUntil(in: host) {
                invalidations > previous && host.intrinsicContentSize.height == height
            }
        }
    }

    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func nativeTableReceivesTheBarsInsetsWhileExtendingUnderThem() async throws {
        let bars = TableBars()
        let host = NSHostingView(rootView: TableBarFixture(bars: bars).frame(width: 400, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func find(_ view: NSView) -> TranscriptTableScrollView? {
            if let scroll = view as? TranscriptTableScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        try await transcriptUntil(in: host) { find(host) != nil }
        let scroll = try #require(find(host))
        for bottom: CGFloat in [100, 176, 240, 100] {
            bars.bottom = bottom
            try await transcriptUntil(in: host, failure: {
                "Expected bottom \(bottom), got \(scroll.contentInsets), bounds \(scroll.bounds),"
                    + " safe area \(scroll.safeAreaInsets), still mounted \(find(host) === scroll)."
            }) { scroll.contentInsets.bottom == bottom }
            try await transcriptSettled(in: host) {
                CGSize(width: scroll.contentInsets.top, height: scroll.contentInsets.bottom)
            }
            #expect(scroll.automaticallyAdjustsContentInsets)
            #expect(scroll.contentInsets.top == 50)
            #expect(scroll.contentInsets.bottom == bottom)
            #expect(scroll.bounds.height == 600)
        }
    }

    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func nativeTableAccessoriesDoNotCountTheWindowToolbarTwice() async throws {
        let scroll = NSScrollView()
        scroll.automaticallyAdjustsContentInsets = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 2_000))
        let controller = TranscriptTableEdges(content: scroll)
        let window = NSWindow(contentRect: NSRect(x: -6_000, y: -6_000, width: 720, height: 840),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "transcript-edge-fixture")
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 720, height: 840))
        defer { window.close() }
        let top = controller.view.bounds.maxY - window.contentLayoutRect.maxY
        #expect(top > 0)
        for bottom: CGFloat in [100, 176, 240, 100] {
            controller.update(top: top, bottom: bottom)
            try await transcriptUntil(in: controller.view) { scroll.contentInsets.bottom == bottom }
            try await transcriptSettled(in: controller.view) {
                CGSize(width: scroll.contentInsets.top, height: scroll.contentInsets.bottom)
            }
            #expect(scroll.frame == controller.view.bounds)
            #expect(scroll.contentInsets.top == top)
            #expect(scroll.contentInsets.bottom == bottom)
            #expect(controller.topEdge.view.bounds.height == 0)
            #expect(controller.bottomEdge.view.bounds.height == bottom)
        }
    }

    @Test(.enabled(if: transcriptTimingTestsEnabled), arguments: [false, true], [CGFloat(0), 248])
    func nativeDocumentKeepsSwiftUIScrollOwnershipAndRealRowHeights(landsOnUnread: Bool,
                                                                   leading: CGFloat) async throws {
        let setup = try setup()
        var messages = (1...24).map(transcriptTestMessage)
        messages[23].sender = .user
        messages[23].content = .text(String(repeating: "A right-aligned message that wraps inside the visible lane. ",
                                            count: 12))
        let items = TranscriptTableItem.project(transcriptRows(messages,
                                                               lead: setup.lead, members: [],
                                                               unreadAfter: landsOnUnread ? 12 : nil))
        let content = content(items, setup: setup)
        let bars = TableBars()
        bars.leading = leading
        let draws = DocumentDraws()
        let host = NSHostingView(rootView: DocumentBarFixture(bars: bars, items: items, content: content,
                                                             onDraw: { document in
            guard let scroll = document.enclosingScrollView,
                  document.coordinator.table.numberOfRows == items.count + 1 else { return }
            let table = document.coordinator.table
            let error: CGFloat
            if let target = items.firstIndex(where: { $0.row.divider?.unread == true }) {
                error = table.rect(ofRow: target + 1).minY
                    - scroll.contentView.bounds.minY - scroll.contentInsets.top
            } else {
                error = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom
                    - table.rect(ofRow: items.count).maxY - TranscriptScrollModel.endClearance
            }
            draws.errors.append(error)
        })
            .environment(\.self, setup.environment).frame(width: 980, height: 600))
        let window = NSWindow(contentRect: NSRect(x: -6_000, y: -6_000, width: 980, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func find(_ view: NSView) -> TranscriptTableDocument? {
            if let document = view as? TranscriptTableDocument { return document }
            return view.subviews.lazy.compactMap(find).first
        }
        try await transcriptUntil(in: host) {
            guard let document = find(host), let scroll = document.enclosingScrollView else { return false }
            return document.bounds.height > 0 && document.coordinator.table.numberOfRows == items.count + 1
                && scroll.contentInsets.bottom == 100
        }
        let document = try #require(find(host))
        let scroll = try #require(document.enclosingScrollView)
        let hostingDocument = try #require(scroll.documentView)
        let table = document.coordinator.table
        #expect(hostingDocument !== document && hostingDocument !== table)
        #expect(table.enclosingScrollView === scroll)
        try await transcriptSettled(in: host) {
            CGSize(width: scroll.contentView.bounds.minY, height: document.bounds.height)
        }
        try await transcriptUntil(in: host) {
            document.coordinator.messageFrames.values.contains { $0.values.contains { $0.sequence > 0 } }
        }
        for (id, measured) in document.coordinator.messageFrames {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            let row = table.rect(ofRow: index + 1)
            guard row.intersects(table.visibleRect) else { continue }
            for message in measured.values where message.sequence > 0 {
                let local = CGRect(x: message.rect.minX, y: row.minY + message.contentTop,
                                   width: message.rect.width, height: message.rect.height)
                let expected = table.convert(local, to: host)
                #expect(abs(message.windowRect.minX - expected.minX) <= 0.5)
                #expect(abs(message.windowRect.minY - expected.minY) <= 0.5)
            }
        }
        if landsOnUnread {
            let target = try #require(items.firstIndex { $0.row.divider?.unread == true })
            let viewportTop = scroll.contentView.bounds.minY + scroll.contentInsets.top
            #expect(abs(table.rect(ofRow: target + 1).minY - viewportTop) <= 0.5)
        } else {
            let lastMessageEnd = table.rect(ofRow: items.count).maxY
            let viewportBottom = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom
            #expect(abs(viewportBottom - lastMessageEnd - 16) <= 0.5)
        }
        let landingIntent = document.coordinator.scrollIntent
        for bottom: CGFloat in [100, 176, 240, 100] {
            bars.bottom = bottom
            document.needsDisplay = true
            try await transcriptUntil(in: host) { scroll.contentInsets.bottom == bottom }
            try await transcriptSettled(in: host) {
                CGSize(width: document.bounds.width, height: document.bounds.height)
            }
            #expect(scroll.documentView === hostingDocument)
            #expect(scroll.bounds.height == 600)
            #expect(scroll.bounds.width == 980)
            #expect(scroll.contentInsets.top == 50)
            #expect(scroll.contentInsets.left == leading)
            #expect(scroll.contentInsets.bottom == bottom)
            #expect(abs(table.frame.width - (980 - leading)) <= 0.5)
            let tableLeft = table.convert(.zero, to: nil).x
            let viewportLeft = scroll.convert(CGPoint(x: leading, y: 0), to: nil).x
            #expect(abs(tableLeft - viewportLeft) <= 0.5)
            #expect(abs(document.bounds.height - document.coordinator.documentHeight) <= 0.5)
            #expect(abs(hostingDocument.bounds.height - document.bounds.height) <= 0.5)
            #expect(abs(table.frame.height - document.bounds.height) <= 0.5)
            #expect(document.coordinator.scrollIntent == landingIntent)
            if landsOnUnread {
                let target = try #require(items.firstIndex { $0.row.divider?.unread == true })
                let viewportTop = scroll.contentView.bounds.minY + scroll.contentInsets.top
                #expect(abs(table.rect(ofRow: target + 1).minY - viewportTop) <= 0.5)
            } else {
                let viewportBottom = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom
                #expect(abs(viewportBottom - table.rect(ofRow: items.count).maxY - 16) <= 0.5)
            }
        }
        #expect(!draws.errors.isEmpty)
        #expect(draws.errors.allSatisfy { abs($0) <= 0.5 })
    }

    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func nativeDocumentKeepsTheReaderThroughAppendPrependReflowAndNoOpLayout() async throws {
        let setup = try setup()
        let bars = TableBars()
        bars.leading = 248
        var messages = (101...200).map(transcriptTestMessage)
        for index in messages.indices {
            messages[index].content = .text(String(repeating: "A paragraph that wraps when the lane narrows. ",
                                                  count: 3 + index % 5))
        }
        let data = TableData()
        func setMessages() {
            data.items = TranscriptTableItem.project(transcriptRows(messages, lead: setup.lead, members: []))
            data.content = content(data.items, setup: setup)
        }
        setMessages()
        let state = TranscriptDocumentState()
        let host = NSHostingView(rootView: MutableDocumentFixture(bars: bars, data: data, state: state)
            .environment(\.self, setup.environment))
        let window = NSWindow(contentRect: NSRect(x: -6_000, y: -6_000, width: 980, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func find(_ view: NSView) -> TranscriptTableDocument? {
            if let document = view as? TranscriptTableDocument { return document }
            return view.subviews.lazy.compactMap(find).first
        }
        try await transcriptUntil(in: host) { state.snapshot.hasLanded && find(host) != nil }
        let document = try #require(find(host))
        let scroll = try #require(document.enclosingScrollView)
        let table = document.coordinator.table
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        #expect(document.coordinator.measurementCount < 50)
        func readerMoves(to origin: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: origin))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        }
        readerMoves(to: table.rect(ofRow: 51).minY + 12 - scroll.contentInsets.top)
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        guard case .reading(let anchor) = document.coordinator.scrollIntent else {
            Issue.record("A recorded reader scroll did not produce a reading anchor.")
            return
        }
        func anchorOffset() throws -> CGFloat {
            let index = try #require(data.items.firstIndex { $0.id == anchor.row })
            return table.rect(ofRow: index + 1).minY - scroll.contentView.bounds.minY - scroll.contentInsets.top
        }
        let offset = try anchorOffset()
        #expect(!state.snapshot.isAtBottom)
        messages.append(transcriptTestMessage(201))
        setMessages()
        try await transcriptUntil(in: host) { table.numberOfRows == data.items.count + 1 }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        #expect(abs(try anchorOffset() - offset) <= 0.5)
        messages = (1...100).map(transcriptTestMessage) + messages
        setMessages()
        try await transcriptUntil(in: host) { table.numberOfRows == data.items.count + 1 }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        #expect(abs(try anchorOffset() - offset) <= 0.5)
        for width: CGFloat in [760, 980, 760, 980] {
            window.setContentSize(NSSize(width: width, height: 600))
            try await transcriptUntil(in: host, failure: {
                "Expected table width \(width - 248), got \(table.frame.width). Window \(window.frame),"
                    + " host \(host.frame), scroll \(scroll.frame), clip \(scroll.contentView.frame),"
                    + " document \(document.frame), insets \(scroll.contentInsets)."
            }) { abs(table.frame.width - (width - 248)) <= 0.5 }
            try await transcriptSettled(in: host) {
                CGSize(width: table.frame.width, height: scroll.contentView.bounds.minY)
            }
            #expect(abs(try anchorOffset() - offset) <= 0.5)
        }
        #expect(document.coordinator.reusedCellCount > 0)
        let target = data.items[150]
        let sequence = try #require(target.row.messages.first?.sequence)
        state.send(.reveal(target.id))
        try await transcriptUntil(in: host) {
            document.coordinator.messageFrames[target.id]?.values.contains { $0.sequence == sequence } == true
        }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        func messageTop() throws -> CGFloat {
            let index = try #require(data.items.firstIndex { $0.id == target.id })
            let local = try #require(document.coordinator.messageFrames[target.id]?.values.first {
                $0.sequence == sequence
            })
            #expect(local.rect.height > 48)
            return table.rect(ofRow: index + 1).minY + local.contentTop
        }
        readerMoves(to: try messageTop() + 23 - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
        try await transcriptSettled(in: host) {
            CGSize(width: scroll.contentView.bounds.minY, height: CGFloat(state.snapshot.visibleSequence ?? 0))
        }
        #expect((state.snapshot.visibleSequence ?? 0) < sequence)
        readerMoves(to: try messageTop() + 25 - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
        try await transcriptSettled(in: host) {
            CGSize(width: scroll.contentView.bounds.minY, height: CGFloat(state.snapshot.visibleSequence ?? 0))
        }
        #expect(state.snapshot.visibleSequence == sequence)
        state.send(.jumpToLatest)
        try await transcriptUntil(in: host) { state.snapshot.isAtBottom }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        let end = scroll.contentView.bounds.minY
        readerMoves(to: end - 30)
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        let nearEnd = scroll.contentView.bounds.minY
        document.needsLayout = true
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        #expect(abs(scroll.contentView.bounds.minY - nearEnd) <= 0.5)
        data.holdsPosition = true
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        guard case .reading = document.coordinator.scrollIntent else {
            Issue.record("Find did not hold a near-end reading position.")
            return
        }
        #expect(abs(scroll.contentView.bounds.minY - nearEnd) <= 0.5)
        data.holdsPosition = false
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        #expect(document.coordinator.scrollIntent == .following)
        #expect(abs(scroll.contentView.bounds.minY - nearEnd) <= 0.5)
        messages.append(transcriptTestMessage(202))
        setMessages()
        try await transcriptUntil(in: host) { table.numberOfRows == data.items.count + 1 }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        let bottom = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom
        #expect(abs(bottom - table.rect(ofRow: data.items.count).maxY - 16) <= 0.5)
        data.holdsPosition = true
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        guard case .reading(let held) = document.coordinator.scrollIntent else {
            Issue.record("Find did not hold the end against incoming messages.")
            return
        }
        func heldOffset() throws -> CGFloat {
            let index = try #require(data.items.firstIndex { $0.id == held.row })
            return table.rect(ofRow: index + 1).minY - scroll.contentView.bounds.minY - scroll.contentInsets.top
        }
        let heldAt = try heldOffset()
        messages.append(transcriptTestMessage(203))
        setMessages()
        try await transcriptUntil(in: host) { table.numberOfRows == data.items.count + 1 }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        #expect(abs(try heldOffset() - heldAt) <= 0.5)
        data.holdsPosition = false
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        state.send(.ownPostConfirmed)
        try await transcriptUntil(in: host) { state.snapshot.isAtBottom }
        let earlier = Array(messages.prefix(50))
        messages.removeFirst(50)
        setMessages()
        try await transcriptUntil(in: host) { table.numberOfRows == data.items.count + 1 }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        #expect(document.coordinator.scrollIntent == .following)
        readerMoves(to: -scroll.contentInsets.top)
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        guard case .reading(let first) = document.coordinator.scrollIntent else {
            Issue.record("A reader at the history header did not anchor a message.")
            return
        }
        #expect(first.row == data.items.first?.id)
        let firstOffset = table.rect(ofRow: 1).minY - scroll.contentView.bounds.minY - scroll.contentInsets.top
        messages = earlier + messages
        setMessages()
        try await transcriptUntil(in: host) { table.numberOfRows == data.items.count + 1 }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        let restoredIndex = try #require(data.items.firstIndex { $0.id == first.row })
        let restored = table.rect(ofRow: restoredIndex + 1).minY
            - scroll.contentView.bounds.minY - scroll.contentInsets.top
        #expect(abs(restored - firstOffset) <= 0.5)
    }

    @Test(.enabled(if: transcriptTimingTestsEnabled),
          arguments: ["page-up", "home", "ax-older-page", "up-arrow", "scroller", "scroll-to-visible",
                      "page-down", "down-arrow", "end", "home-during-inset-change"])
    func nativeReaderInputsKeepTheirPositionWhenTheNextMessageArrives(_ input: String) async throws {
        let setup = try setup()
        let bars = TableBars()
        bars.leading = 248
        let data = TableData()
        var messages = (1...100).map(transcriptTestMessage)
        func setMessages() {
            data.items = TranscriptTableItem.project(transcriptRows(messages, lead: setup.lead, members: []))
            data.content = content(data.items, setup: setup)
        }
        setMessages()
        let find = TranscriptFind()
        var readerEvents = 0
        let state = TranscriptDocumentState()
        let host = NSHostingView(rootView: MutableDocumentFixture(bars: bars, data: data, state: state,
                                                                 onReaderScroll: { _ in
            readerEvents += 1
            find.resumeReading()
        }).environment(\.self, setup.environment))
        let window = InputWindow(contentRect: NSRect(x: -6_000, y: -6_000, width: 980, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func findDocument(_ view: NSView) -> TranscriptTableDocument? {
            if let document = view as? TranscriptTableDocument { return document }
            return view.subviews.lazy.compactMap(findDocument).first
        }
        try await transcriptUntil(in: host) { state.snapshot.hasLanded && findDocument(host) != nil }
        let document = try #require(findDocument(host))
        let table = document.coordinator.table
        let scroll = try #require(document.enclosingScrollView)
        try #require(window.makeFirstResponder(table))
        state.send(.jumpToLatest)
        try await transcriptUntil(in: host) { document.coordinator.scrollIntent == .following }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        func key(_ code: UInt16, _ characters: String) throws {
            window.sendEvent(try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)))
        }
        func lastVisibleSequence() -> Int? {
            let top = scroll.contentView.bounds.minY + scroll.contentInsets.top
            let bottom = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom
            return data.items.enumerated().flatMap { index, item in
                let row = table.rect(ofRow: index + 1)
                return (document.coordinator.messageFrames[item.id] ?? [:]).values.compactMap { message -> Int? in
                    guard message.sequence > 0, message.rect.height > 0 else { return nil }
                    let messageTop = row.minY + message.contentTop
                    let overlap = min(bottom, messageTop + message.rect.height) - max(top, messageTop)
                    return overlap >= min(24, message.rect.height / 2) ? message.sequence : nil
                }
            }.max()
        }
        if input == "scroll-to-visible" {
            table.scrollRowToVisible(45)
            try await transcriptUntil(in: host) {
                let visible = lastVisibleSequence()
                return visible != nil && state.snapshot.visibleSequence == visible
            }
            try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
            try key(119, "\u{f72b}")
            try await transcriptUntil(in: host) {
                state.snapshot.isAtBottom && state.snapshot.visibleSequence == 100
            }
            try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        }
        if ["page-down", "down-arrow", "end"].contains(input) {
            try key(115, "\u{f729}")
            try await transcriptUntil(in: host) { !state.snapshot.isAtBottom }
            try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        }
        find.present()
        find.close()
        let before = scroll.contentView.bounds.minY
        let beforeEvents = readerEvents
        let pageDistance = max(0, scroll.contentView.bounds.height - scroll.contentInsets.top
                               - scroll.contentInsets.bottom - scroll.verticalPageScroll)
        func remainingToEnd() -> CGFloat {
            table.rect(ofRow: data.items.count).maxY + 16
                - scroll.contentView.bounds.maxY + scroll.contentInsets.bottom
        }
        switch input {
        case "page-up": try key(116, "\u{f72c}")
        case "home": try key(115, "\u{f729}")
        case "home-during-inset-change":
            bars.bottom = 176
            scroll.contentInsets.bottom = 176
            try key(115, "\u{f729}")
        case "up-arrow":
            for _ in 0..<6 { try key(126, "\u{f700}") }
        case "page-down": try key(121, "\u{f72d}")
        case "down-arrow": try key(125, "\u{f701}")
        case "end": try key(119, "\u{f72b}")
        case "ax-older-page":
            try performOlderPageAccessibilityAction(in: scroll)
        case "scroll-to-visible":
            for row in [20, 70, 45] { table.scrollRowToVisible(row) }
            document.coordinator.stopObserving()
            document.coordinator.attach(scroll, ownsDocument: false, document: document)
        case "scroller":
            let scroller = try #require(scroll.verticalScroller)
            scroller.setAccessibilityValue(NSNumber(value: 0.5))
        default:
            Issue.record("Unknown native reader input \(input).")
            return
        }
        try await transcriptUntil(in: host, timeout: .seconds(5), failure: {
            "\(input) did not move the native reader. Origin \(scroll.contentView.bounds.minY),"
                + " previous \(before), input callbacks \(readerEvents - beforeEvents),"
                + " responder \(String(describing: window.firstResponder))."
        }) {
            abs(scroll.contentView.bounds.minY - before) > 0.5 && readerEvents > beforeEvents
                && (input != "page-up" || abs(remainingToEnd() - pageDistance) <= 0.5)
                && (input != "page-down"
                    || abs(scroll.contentView.bounds.minY + scroll.contentInsets.top - pageDistance) <= 0.5)
        }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        #expect(!find.blocksRead)
        let visibleSequence = lastVisibleSequence()
        #expect(visibleSequence != nil)
        #expect(state.snapshot.visibleSequence == visibleSequence)
        #expect(document.coordinator.measurementCount < 50)
        let anchor: TranscriptScrollModel.Anchor?
        if case .reading(let reading) = document.coordinator.scrollIntent {
            anchor = reading
        } else {
            #expect(input == "end" && document.coordinator.scrollIntent == .following)
            anchor = nil
        }
        func anchorOffset(_ anchor: TranscriptScrollModel.Anchor) throws -> CGFloat {
            let index = try #require(data.items.firstIndex { $0.id == anchor.row })
            return table.rect(ofRow: index + 1).minY - scroll.contentView.bounds.minY - scroll.contentInsets.top
        }
        let offset = try anchor.map(anchorOffset)
        messages.append(transcriptTestMessage(101))
        setMessages()
        try await transcriptUntil(in: host) { table.numberOfRows == data.items.count + 1 }
        try await transcriptSettled(in: host) { scroll.contentView.bounds.origin }
        if let anchor, let offset {
            #expect(abs(try anchorOffset(anchor) - offset) <= 0.5)
            #expect(!state.snapshot.isAtBottom)
        } else {
            let bottom = scroll.contentView.bounds.maxY - scroll.contentInsets.bottom
            #expect(abs(bottom - table.rect(ofRow: data.items.count).maxY - 16) <= 0.5)
        }
    }

    private func performOlderPageAccessibilityAction(in root: NSObject) throws {
        // AX describes the direction the content moves, opposite the viewport's movement.
        let action = NSAccessibility.Action(rawValue: "AXScrollDownByPage")
        var queue = [root]
        var visited: Set<ObjectIdentifier> = []
        var actions: Set<String> = []
        while let element = queue.popLast(), visited.count < 2_000 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let supported = element.accessibilityActionNames()
            actions.formUnion(supported.map(\.rawValue))
            if supported.contains(action) {
                element.accessibilityPerformAction(action)
                return
            }
            if element.accessibilityAttributeNames().contains(.children),
               let children = element.accessibilityAttributeValue(.children) as? [NSObject] {
                queue.append(contentsOf: children)
            }
        }
        throw NativeInputFailure(message: "No AX older-page action in \(visited.count) elements. Actions: \(actions.sorted()).")
    }

    private struct NativeInputFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private final class InputWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func tableHeightMeasurementReportsColdWarmAndAppendCost() throws {
        let setup = try setup()
        for count in [100, 542] {
            for oneRun in [false, true] {
                let messages = oneRun ? (1...count).map(transcriptTestMessage) : transcriptFindTestMessages(1...count)
                let items = TranscriptTableItem.project(transcriptRows(messages, lead: setup.lead, members: []))
                let content = content(items, setup: setup)
                let cache = TranscriptTableHeights()
                let clock = ContinuousClock()
                let coldStart = clock.now
                let cold = cache.resolve(items: items, content: content, width: 720, environment: setup.environment)
                let coldDuration = coldStart.duration(to: clock.now)
                let warmStart = clock.now
                let warm = cache.resolve(items: items, content: content, width: 720, environment: setup.environment)
                let warmDuration = warmStart.duration(to: clock.now)
                let appended = messages + [transcriptTestMessage(count + 1)]
                let newItems = TranscriptTableItem.project(transcriptRows(appended, lead: setup.lead, members: []))
                let newContent = self.content(newItems, setup: setup)
                let appendStart = clock.now
                let result = cache.resolve(items: newItems, content: newContent, width: 720,
                                           environment: setup.environment)
                let appendDuration = appendStart.duration(to: clock.now)
                #expect(cold.measured == count && warm.measured == 0 && result.measured == 1)
                let widthStart = clock.now
                let reflow = cache.resolve(items: newItems, content: newContent, width: 420,
                                           environment: setup.environment)
                let widthDuration = widthStart.duration(to: clock.now)
                #expect(reflow.measured == count + 1)
                print("TABLE_HEIGHTS count=\(count) one_run=\(oneRun) cold_ms=\(milliseconds(coldDuration))"
                      + " warm_ms=\(milliseconds(warmDuration)) append_ms=\(milliseconds(appendDuration))"
                      + " width_ms=\(milliseconds(widthDuration))"
                      + " append_measured=\(result.measured)")
            }
        }
    }

    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func boundedHeightMeasurementReportsColdReflowAndAppendCost() throws {
        let setup = try setup()
        for count in [100, 542] {
            let messages = transcriptFindTestMessages(1...count)
            let items = TranscriptTableItem.project(transcriptRows(messages, lead: setup.lead, members: []))
            let content = content(items, setup: setup)
            let cache = TranscriptTableHeights()
            let clock = ContinuousClock()
            let tail = IndexSet((items.count - 10)..<items.count)
            let coldStart = clock.now
            let cold = cache.resolve(items: items, content: content, width: 720,
                                     environment: setup.environment, measuring: tail)
            let coldDuration = coldStart.duration(to: clock.now)
            let widthStart = clock.now
            let narrow = cache.resolve(items: items, content: content, width: 420,
                                       environment: setup.environment, measuring: tail)
            let widthDuration = widthStart.duration(to: clock.now)
            let appended = messages + [transcriptTestMessage(count + 1)]
            let newItems = TranscriptTableItem.project(transcriptRows(appended, lead: setup.lead, members: []))
            let newContent = self.content(newItems, setup: setup)
            let appendStart = clock.now
            let result = cache.resolve(items: newItems, content: newContent, width: 720,
                                       environment: setup.environment,
                                       measuring: IndexSet((newItems.count - 10)..<newItems.count))
            let appendDuration = appendStart.duration(to: clock.now)
            #expect(cold.measured == 10 && narrow.measured == 10 && result.measured == 1)
            print("BOUNDED_TABLE_HEIGHTS count=\(count) cold_ms=\(milliseconds(coldDuration))"
                  + " width_ms=\(milliseconds(widthDuration)) append_ms=\(milliseconds(appendDuration))"
                  + " cold_measured=\(cold.measured) width_measured=\(narrow.measured)"
                  + " append_measured=\(result.measured)")
        }
    }

    private struct Setup {
        let lead: ChannelAgent
        let store: ChannelStore
        let environment: EnvironmentValues
    }

    @Observable
    fileprivate final class TableBars {
        var bottom: CGFloat = 100
        var leading: CGFloat = 0
    }

    @Observable
    fileprivate final class TableData {
        var items: [TranscriptTableItem] = []
        var content: [TranscriptRowContent] = []
        var holdsPosition = false
    }

    private final class DocumentDraws {
        var errors: [CGFloat] = []
    }

    @Observable
    fileprivate final class HostedHeight {
        var height: CGFloat = 80
    }

    private struct HostedHeightFixture: View {
        let data: HostedHeight

        var body: some View {
            Color.clear.frame(width: 300, height: data.height).fixedSize()
        }
    }

    private struct MutableDocumentFixture: View {
        let bars: TableBars
        let data: TableData
        let state: TranscriptDocumentState
        var onReaderScroll: ((Bool) -> Void)? = nil

        var body: some View {
            ScrollView {
                TranscriptDocumentPrototype(items: data.items, content: data.content,
                                            header: AnyView(Color.clear.frame(height: 12)), state: state,
                                            command: state.command, holdsPosition: data.holdsPosition,
                                            onReaderScroll: onReaderScroll)
            }
            .onScrollPhaseChange { _, phase in state.coordinator?.readerPhaseChanged(phase) }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .top, spacing: 0) { Color.clear.frame(height: 50) }
            .safeAreaBar(edge: .bottom, spacing: 0) { Color.clear.frame(height: bars.bottom) }
            .safeAreaPadding(.leading, bars.leading)
            .frame(height: 600)
        }
    }

    private struct TableBarFixture: View {
        let bars: TableBars

        var body: some View {
            GeometryReader { geometry in
                TranscriptTablePrototype(items: [], content: [],
                                         header: AnyView(Color.clear.frame(height: 12)),
                                         insets: geometry.safeAreaInsets)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
            .safeAreaBar(edge: .top, spacing: 0) { Color.clear.frame(height: 50) }
            .safeAreaBar(edge: .bottom, spacing: 0) { Color.clear.frame(height: bars.bottom) }
        }
    }

    private struct DocumentBarFixture: View {
        let bars: TableBars
        let items: [TranscriptTableItem]
        let content: [TranscriptRowContent]
        var onDraw: ((TranscriptTableDocument) -> Void)? = nil

        var body: some View {
            ScrollView {
                TranscriptDocumentPrototype(items: items, content: content,
                                            header: AnyView(Color.clear.frame(height: 12)), onDraw: onDraw)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .top, spacing: 0) { Color.clear.frame(height: 50) }
            .safeAreaBar(edge: .bottom, spacing: 0) { Color.clear.frame(height: bars.bottom) }
            .safeAreaPadding(.leading, bars.leading)
        }
    }

    private func setup() throws -> Setup {
        let api = try ChannelAPI(serverURL: "https://table-heights.invalid")
        let store = ChannelStore(id: "table-heights", api: api, sendJournal: nil)
        var environment = EnvironmentValues()
        environment[ChannelInteraction.self] = ChannelInteraction()
        environment[ArtifactOpener.self] = ArtifactOpener()
        return Setup(lead: .lead(id: "lead"), store: store, environment: environment)
    }

    private func content(_ items: [TranscriptTableItem], setup: Setup) -> [TranscriptRowContent] {
        let context = TranscriptRowContext(agents: [setup.lead], channelID: setup.store.id,
                                           historyStart: 1, api: setup.store.api)
        return items.map { item in
            TranscriptRowContent(row: item.row, context: context, statusReactions: [:], highlightedSequence: nil,
                                 catchUp: nil, store: setup.store, expandedMessageIds: [],
                                 showsAgentAvatar: item.showsAvatar, onSetExpanded: { _, _ in })
        }
    }

    private func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.2f", Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }
}

@Suite("Transcript rendering and visibility")
struct TranscriptTests {
    @Test func paragraphsKeepSelectableInlineMarkdownAndLineBreaks() {
        #expect(MarkdownBlock.parse("").isEmpty)
        #expect(MarkdownBlock.parse(" \n\n ").isEmpty)
        let blocks = MarkdownBlock.parse("Hello **team** and @lead.\nA second line.\n\nNext paragraph.")
        #expect(blocks.map(\.kind) == [
            .paragraph("Hello **team** and @lead.\nA second line."),
            .paragraph("Next paragraph.")
        ])
        #expect(blocks.map(\.id) == [0, 1])
    }

    @Test func revealRejectsUnmeasuredAndPrependStaleTargets() throws {
        let viewport = TranscriptViewport(top: 1_890, width: 503, height: 380, contentHeight: 5_148)
        let stale = TranscriptMessageFrame(sequence: 2, rect: CGRect(x: 0, y: -1_800, width: 400, height: 57),
                                           historyStart: 61, contentTop: 70)
        #expect(TranscriptReveal.Layout(frame: nil, historyStart: 1, viewport: viewport, nativeTop: 1_890) == nil)
        #expect(TranscriptReveal.Layout(frame: stale, historyStart: 1, viewport: viewport, nativeTop: 1_890) == nil)
        var current = stale
        current.historyStart = 1
        current.rect.origin.y = 100
        let layout = try #require(TranscriptReveal.Layout(
            frame: current, historyStart: 1, viewport: viewport, nativeTop: 1_890))
        #expect(TranscriptCoordinates.targetOffset(for: current, bottom: layout.bottom, topInset: 0) == -71.5)
        #expect(TranscriptReveal.Layout(frame: current, historyStart: 1, viewport: .init(), nativeTop: 0) == nil)
        var reveal = TranscriptReveal()
        let first = reveal.receive(layout, isAligned: false)
        let next = reveal.receive(layout, isAligned: false)
        #expect(!first && !next)
    }

    @Test func revealCompletesOnlyAfterAnUnchangedNativeAlignment() throws {
        let viewport = TranscriptViewport(top: 1_890, width: 503, height: 380, contentHeight: 5_148)
        let frame = TranscriptMessageFrame(sequence: 2, rect: CGRect(x: 0, y: -1_800, width: 400, height: 57),
                                           historyStart: 1, contentTop: 70)
        let layout = try #require(TranscriptReveal.Layout(
            frame: frame, historyStart: 1, viewport: viewport, nativeTop: 1_890))
        #expect(layout.bottom == 218.5)
        var reveal = TranscriptReveal()
        var completions = [reveal.receive(layout, isAligned: true)]
        var corrected = layout
        corrected.frame.contentTop += 120
        completions.append(reveal.receive(corrected, isAligned: true))
        corrected.nativeTop += 40
        completions.append(reveal.receive(corrected, isAligned: true))
        completions.append(reveal.receive(nil, isAligned: false))
        completions.append(reveal.receive(corrected, isAligned: true))
        completions.append(reveal.receive(corrected, isAligned: true))
        #expect(completions == [false, false, false, false, false, true])
    }

    @MainActor
    @Test(arguments: [0.9, 1, 1.2])
    func markdownSizingKeepsTranscriptDefaultsAndScalesArtifactCode(_ scale: CGFloat) throws {
        let normal = TranscriptMarkdown(content: "Body and `code`")
        #expect(normal.bodySize == 14 && normal.codeSize == 12 && normal.lineSpacing == 3)
        let artifact = TranscriptMarkdown(content: "Body and `code`", bodySize: 15, codeSize: 13, lineSpacing: 4)
        #expect(artifact.bodySize == 15 && artifact.codeSize == 13 && artifact.lineSpacing == 4)
        let original = transcriptInlineMarkdown("`code` @lead", agents: [.lead(id: "lead")], textScale: scale)
        let resized = transcriptInlineMarkdown("`code` @lead", agents: [.lead(id: "lead")], textScale: scale,
                                               fontSize: artifact.bodySize, codeSize: artifact.codeSize)
        #expect(original.runs.first?.font == .system(size: 12 * scale, design: .monospaced))
        #expect(resized.runs.first?.font == .system(size: 13 * scale, design: .monospaced))
        let mention = try #require(resized.range(of: "@lead"))
        #expect(resized[mention].runs.first?.font == .system(size: 15 * scale, weight: .semibold))
    }

    @Test func headingsQuotesAndListsHaveDistinctBlocks() {
        let source = """
        # Direction
        > A quote
        > continued.

        - One
          - Nested
        2. Two
        - [x] Done
        - [ ] Pending
        """
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .heading(1, "Direction"), .quote("A quote\ncontinued."),
            .listItem("\u{2022}", "One", 0), .listItem("\u{2022}", "Nested", 1),
            .listItem("2.", "Two", 0), .listItem("\u{2611}", "Done", 0),
            .listItem("\u{2610}", "Pending", 0)
        ])
        #expect(MarkdownBlock.parse("Title\n=====\n\nSubtitle\n---\n\n---").map(\.kind) == [
            .heading(1, "Title"), .heading(2, "Subtitle"), .rule
        ])
    }

    @Test func fencedCodeStaysLiteralUntilAMatchingClosingFence() {
        #expect(MarkdownBlock.parse("```swift\nlet x = \"@lead | **not bold**\"\n```\nAfter").map(\.kind) == [
            .code("swift", "let x = \"@lead | **not bold**\""), .paragraph("After")
        ])
        let source = "````markdown\n```swift\nlet x = 1\n```\n````\nAfter"
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .code("markdown", "```swift\nlet x = 1\n```"), .paragraph("After")
        ])
        #expect(MarkdownBlock.parse("~~~text\nOne\nTwo").map(\.kind) == [.code("text", "One\nTwo")])
        #expect(MarkdownBlock.parse("```\n```not a closing fence\nend\n```").map(\.kind) == [
            .code("", "```not a closing fence\nend")
        ])
    }

    @MainActor
    @Test func onlyACodeBlockTooWideToFitBuildsAScrollViewAndCopyCodeIsNoAppKitControl() {
        func platformViews(_ markdown: String) -> [NSView] {
            let host = NSHostingView(rootView: TranscriptMarkdown(content: markdown).frame(width: 400)
                .fixedSize(horizontal: false, vertical: true))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            host.layoutSubtreeIfNeeded()
            func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
            return all(host)
        }
        let fitting = platformViews("```swift\nlet total = messages.count\n```")
        #expect(!fitting.contains { $0 is NSScrollView })
        #expect(!fitting.contains { $0 is NSButton })
        let wide = platformViews("```swift\n" + String(repeating: "let total = messages.count; ", count: 6) + "\n```")
        #expect(wide.contains { $0 is NSScrollView })
    }

    /// Rows turn selection on when the pointer first reaches them, so it must not move or redraw any ink.
    @MainActor
    @Test func turningSelectionOnDrawsTheSameMarkdown() async throws {
        let markdown = "## Pass 4\n\nA paragraph with **bold**, `code` and a [link](https://example.com).\n\n"
            + "- One\n- Two that runs long enough to wrap onto a second line in a narrow lane\n\n"
            + "> A quote\n\n```swift\nlet total = messages.count\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        func pixels(selectable: Bool) async throws -> Data {
            let bitmap = try await renderedTranscriptBitmap(
                TranscriptMarkdown(content: markdown, selectable: selectable), size: CGSize(width: 320, height: 560),
                appearance: NSAppearance(named: .aqua))
            return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let plain = try await pixels(selectable: false)
        let selectable = try await pixels(selectable: true)
        // The two text renderers round the edge of inline code's faint tint half a point apart. Any glyph
        // or line that moved would differ by far more.
        #expect(selectable.count == plain.count)
        #expect(zip(plain, selectable).allSatisfy { abs(Int($0) - Int($1)) <= 16 })
    }

    /// Each selectable `Text` adds a platform view, most of what a long message costs to scroll in, so a
    /// message builds them only once the pointer reaches it, and keeps them so a selection outlasts it.
    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled), arguments: [false, true])
    func messagesBuildSelectableTextOnceThePointerArrives(table: Bool) async throws {
        let message = try await HoveredMessage(id: "arriving", table: table)
        defer { message.close() }
        let mounted = message.platformViews()

        try message.movePointer()
        try await message.waitUntil { message.platformViews() > mounted }
        try await message.settled()

        try message.leavePointer()
        try await message.settled()
        #expect(message.platformViews() > mounted)
    }

    /// A message that scrolls under a still pointer builds nothing while the content moves, but turns
    /// selectable once it holds still, so a drag that starts without moving the pointer still selects.
    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled), arguments: [false, true])
    func messagesUnderAStillPointerTurnSelectableOnceScrollingSettles(table: Bool) async throws {
        let message = try await HoveredMessage(id: "resting", table: table)
        defer { message.close() }
        let mounted = message.platformViews()
        var now: TimeInterval = 1
        var clockReads = 0
        message.pointer.uptime = {
            clockReads += 1
            return now
        }
        message.pointer.settleDelay = 0.05

        message.pointer.contentDidMove()
        try message.movePointer(x: 140)
        try await message.waitUntil { message.pointer.restingID == "resting" }
        try #require(message.pointer.restingID == "resting")
        try await message.waitUntil { clockReads >= 4 }
        #expect(message.platformViews() == mounted)

        now += 1
        try await message.waitUntil { message.platformViews() > mounted }
        #expect(message.pointer.restingID == nil)
    }

    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled), arguments: [false, true])
    func selectableMessageTextCanBecomeFirstResponder(table: Bool) async throws {
        let message = try await HoveredMessage(id: "selecting", table: table)
        defer { message.close() }
        let mounted = message.platformViews()
        try message.movePointer()
        try await message.waitUntil { message.platformViews() > mounted }
        try await message.settled()
        let text = try message.textUnderPointer()
        let acceptsFocus = text.acceptsFirstResponder
        #expect(acceptsFocus, "The text under the pointer must accept focus, not \(type(of: text)).")
        if let native = message.tableView {
            #expect(native.validateProposedFirstResponder(text, for: try message.press()))
        }
    }

    @MainActor
    @Test func aMarkdownTablesBorderHugsItsColumnsInAWideLane() async throws {
        let bitmap = try await renderedTranscriptBitmap(
            TranscriptMarkdown(content: "| A | B |\n| --- | --- |\n| 1 | 2 |", selectable: false)
                .background(Color.white),
            size: CGSize(width: 720, height: 120), appearance: NSAppearance(named: .aqua))
        func colors(at fraction: CGFloat) throws -> [NSColor] {
            let x = Int(CGFloat(bitmap.pixelsWide) * fraction)
            return try (0..<bitmap.pixelsHigh).map {
                try #require(bitmap.colorAt(x: x, y: $0)?.usingColorSpace(.sRGB))
            }
        }
        let table = try colors(at: 0.05)
        let outside = try colors(at: 0.75)
        #expect(table.contains { min($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.99 })
        #expect(outside.allSatisfy { min($0.redComponent, $0.greenComponent, $0.blueComponent) >= 0.99 })
    }

    @Test func tablesKeepEscapedPipesAndInlineCodeTogether() {
        let source = """
        | Name | Value |
        | :--- | ---: |
        | left\\|right | `a|b` |
        | trailing | value |
        """
        #expect(MarkdownBlock.parse(source).map(\.kind) == [
            .table([["Name", "Value"], ["left\\|right", "`a|b`"], ["trailing", "value"]])
        ])
        #expect(MarkdownBlock.parse("one | two\nnot a table").map(\.kind) == [
            .paragraph("one | two\nnot a table")
        ])
    }

    @Test func htmlRemainsInertText() {
        let html = "<script>alert('never execute')</script>"
        #expect(MarkdownBlock.parse(html).map(\.kind) == [.paragraph(html)])
    }

    @Test func knownMentionsAreTintedButCodeLinksAndUnknownHandlesStayLiteral() {
        let lead = ChannelAgent.lead(id: "channel")
        var rendered = transcriptInlineMarkdown("@lead @unknown `@lead` [@lead](https://example.com) @everyone",
                                                agents: [lead])
        #expect(String(rendered.characters) == "@lead @unknown @lead @lead @everyone")
        var tinted = rendered.runs.filter { $0.foregroundColor != nil }
            .map { String(rendered[$0.range].characters) }
        #expect(tinted == ["@lead", "@everyone"])
        #expect(rendered.runs.filter { $0.link != nil }.count == 1)
        rendered = transcriptInlineMarkdown("Caf\u{00e9} **ready**: @lead", agents: [lead])
        #expect(String(rendered.characters) == "Caf\u{00e9} ready: @lead")
        tinted = rendered.runs.filter { $0.foregroundColor != nil }
            .map { String(rendered[$0.range].characters) }
        #expect(tinted == ["@lead"])
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @MainActor
    @Test func mentionInkKeepsItsIdentityHueAtTextContrastOnEverySurface() throws {
        let colors = ["#7fa171", "#ffffff", "#000000", "#ffff00", "#00ffff", "#ff0000", "#123"]
        let surfaces: [TranscriptSurface] = [.canvas, .agent, .pendingAgent, .user]
        for (name, isDark, isIncreased) in [(NSAppearance.Name.aqua, false, false), (.darkAqua, true, false),
                                            (.accessibilityHighContrastAqua, false, true),
                                            (.accessibilityHighContrastDarkAqua, true, true)] {
            let appearance = try #require(NSAppearance(named: name))
            for surface in surfaces {
                let ink = TranscriptMentionInk(surface: surface, isDark: isDark, isContrastIncreased: isIncreased)
                for color in colors {
                    let agent = ChannelAgent(id: "moss", name: "Moss", avatar: .init(mark: "M4 12H20", color: color))
                    let rendered = transcriptInlineMarkdown("@moss and **@everyone**", agents: [agent],
                                                            textScale: 1.25, fontSize: 16, mentions: ink)
                    let mentions = rendered.runs.filter { $0.foregroundColor != nil }
                    #expect(mentions.map { String(rendered[$0.range].characters) } == ["@moss", "@everyone"])
                    for mention in mentions {
                        // Ink alone carries a mention, so it never sits on a tint that could clip a selection.
                        #expect(mention.backgroundColor == nil)
                        let bold = mention.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                        #expect(mention.font == .system(size: 20, weight: bold ? .bold : .semibold))
                    }
                    appearance.performAsCurrentDrawingAppearance {
                        let canvases: [NSColor] = surface == .canvas
                            ? [.textBackgroundColor, .windowBackgroundColor] : [.textBackgroundColor]
                        for mention in mentions {
                            guard let foreground = mention.foregroundColor
                                .flatMap({ NSColor($0).usingColorSpace(.sRGB) }) else {
                                Issue.record("Mention ink must resolve to an sRGB color.")
                                continue
                            }
                            for canvas in canvases {
                                guard let canvas = canvas.usingColorSpace(.sRGB) else { continue }
                                var background = (Double(canvas.redComponent), Double(canvas.greenComponent),
                                                  Double(canvas.blueComponent))
                                for fill in surface.fills(isDark: isDark) {
                                    if let fill = NSColor(fill).usingColorSpace(.sRGB) {
                                        background = composite(fill, over: background)
                                    }
                                }
                                let a = luminance(composite(foreground, over: background)), b = luminance(background)
                                let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                                #expect(ratio >= (isIncreased ? 7 : 4.5),
                                        "\(color) on \(surface) in \(name.rawValue): \(ratio)")
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    @Test func mentionInkOnlyMovesAnIdentityColorAsFarAsContrastRequires() throws {
        func ink(_ color: String, isDark: Bool) -> NSColor? {
            let agent = ChannelAgent(id: "moss", name: "Moss", avatar: .init(mark: "M4 12H20", color: color))
            var resolved: NSColor?
            NSAppearance(named: isDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                resolved = NSColor(TranscriptMentionInk(surface: .agent, isDark: isDark).color(for: agent))
                    .usingColorSpace(.sRGB)
            }
            return resolved
        }
        // A color that already reads keeps its exact identity.
        let black = try #require(ink("#000000", isDark: false))
        #expect(black.redComponent < 0.01 && black.greenComponent < 0.01 && black.blueComponent < 0.01)
        let white = try #require(ink("#ffffff", isDark: true))
        #expect(white.redComponent > 0.99 && white.greenComponent > 0.99 && white.blueComponent > 0.99)
        // A mid green darkens in light and lightens in dark, but stays green rather than going gray.
        for isDark in [false, true] {
            let moss = try #require(ink("#7fa171", isDark: isDark))
            #expect(moss.greenComponent > moss.redComponent + 0.02)
            #expect(moss.greenComponent > moss.blueComponent + 0.02)
            #expect(isDark ? moss.greenComponent >= 0.63 : moss.greenComponent < 0.63)
        }
    }

    @MainActor
    @Test func systemLinkInkMeetsTextContrastInBothAppearancesAndIncreasedContrast() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua,
                               .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            appearance.performAsCurrentDrawingAppearance {
                guard let ink = NSColor(TranscriptSystemLinkLabel.ink).usingColorSpace(.sRGB),
                      let surface = NSColor.textBackgroundColor.usingColorSpace(.sRGB) else {
                    Issue.record("System link ink and transcript background must resolve to native sRGB colors.")
                    return
                }
                let background = composite(surface, over: (1, 1, 1))
                let foreground = composite(ink, over: background)
                let a = luminance(foreground), b = luminance(background)
                #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
            }
        }
    }

    @Test func messageAccessibilityIncludesIdentityWithoutDependingOnAVisibleHeader() {
        let label = transcriptMessageAccessibilityLabel(
            author: "Moss", timestamp: "2026-10-22T12:00:00Z", addressee: "Lead", request: .pending)
        #expect(label.hasPrefix("Moss, "))
        #expect(label.contains("To Lead"))
        #expect(label.hasSuffix("Needs your reply"))
        let replied = transcriptMessageAccessibilityLabel(
            author: "Deleted agent", timestamp: "2026-10-22T12:00:00Z", request: .acknowledged)
        #expect(replied.hasPrefix("Deleted agent, "))
        #expect(replied.hasSuffix("Replied"))
        let attempt = transcriptMessageAccessibilityLabel(
            author: "You", timestamp: "2026-10-22T12:00:00Z", delivery: "Not sent")
        #expect(attempt.hasPrefix("You, "))
        #expect(attempt.hasSuffix("Not sent"))
    }

    @MainActor
    @Test(arguments: [TranscriptSurface.user, .agent])
    func bubblesGainAVisibleEdgeOnlyUnderIncreasedContrast(surface: TranscriptSurface) async throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let bubble = Color.clear.frame(width: 80, height: 40).transcriptBubble(surface)
                    .frame(width: 120, height: 60).background(Color(nsColor: .textBackgroundColor))
                    .environment(\._colorSchemeContrast, contrast)
                let bitmap = try await renderedTranscriptBitmap(bubble, size: CGSize(width: 120, height: 60),
                                                                appearance: NSAppearance(named: name))
                let scale = Double(bitmap.pixelsWide) / 120
                func sample(_ x: Double) throws -> (Double, Double, Double) {
                    let color = try #require(bitmap.colorAt(x: Int(x * scale), y: Int(30 * scale))?
                        .usingColorSpace(.sRGB))
                    return (color.redComponent, color.greenComponent, color.blueComponent)
                }
                let canvas = try sample(5), edge = try sample(20.5), inside = try sample(60)
                let a = luminance(edge), b = luminance(canvas)
                if contrast == .increased {
                    #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 3, "\(surface) in \(name.rawValue)")
                } else {
                    #expect(max(abs(edge.0 - inside.0), abs(edge.1 - inside.1), abs(edge.2 - inside.2)) < 0.02,
                            "\(surface) in \(name.rawValue)")
                }
            }
        }
    }

    @MainActor
    @Test func reactionChipsHaveAtLeastTwentyEightPointTargets() {
        let view = NSHostingView(rootView:
            TranscriptReactionChip(emoji: "\u{2705}", label: "Done", reactors: []))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width >= 28)
        #expect(view.fittingSize.height >= 28)
    }

    @MainActor
    @Test func conversationLaneCapsMessageSurfacesWhileTheDockSpansIt() async throws {
        #expect(TranscriptWidthCap(maxWidth: TranscriptWidthCap.agentSurface * 1.25).maxWidth == 950)
        #expect(TranscriptUserLane(maxWidth: TranscriptUserLane.maximumWidth * 1.25).maxWidth == 800)
        let widths: [(conversation: CGFloat, agent: CGFloat, mine: CGFloat)] = [
            (420, 328, 298), (720, 628, 538), (760, 668, 570), (1_000, 760, 640), (1_400, 760, 640),
        ]
        for (width, agentMaximum, mineMaximum) in widths {
            let capture = TranscriptLayoutCapture()
            // Greedy stand-ins take every point offered, so they measure each cap itself.
            let view = NSHostingView(rootView:
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        Color.clear.frame(width: 32, height: 20)
                            .transcriptMessageFrame(id: "avatar", sequence: 1, historyStart: 1)
                        Color.clear.frame(height: 20)
                            .transcriptMessageFrame(id: "agent", sequence: 2, historyStart: 1)
                            .transcriptWidthCap(TranscriptWidthCap.agentSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .modifier(ConversationRail())
                    TranscriptUserLane(maxWidth: TranscriptUserLane.maximumWidth) {
                        Color.clear.frame(height: 20)
                            .transcriptMessageFrame(id: "mine", sequence: 3, historyStart: 1)
                    }
                    .modifier(ConversationRail())
                    Color.clear.frame(height: 20)
                        .transcriptMessageFrame(id: "dock", sequence: 4, historyStart: 1)
                        .modifier(ConversationRail())
                }
                .coordinateSpace(name: "transcript-viewport")
                .onPreferenceChange(TranscriptMessageFrames.self) { capture.frames = $0 }
                .frame(width: width, height: 60))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 60)
            try await transcriptUntil(in: view) { capture.frames.count == 4 }

            let avatar = try #require(capture.frames["avatar"]).rect
            let agent = try #require(capture.frames["agent"]).rect
            let mine = try #require(capture.frames["mine"]).rect
            let dock = try #require(capture.frames["dock"]).rect
            #expect(abs(avatar.minX - 24) < 0.5)
            #expect(abs(agent.minX - avatar.minX - 44) < 0.5)
            #expect(abs(agent.width - agentMaximum) < 0.5, "Agent surface at \(width): \(agent.width)")
            #expect(abs(mine.maxX - (width - 24)) < 0.5)
            #expect(abs(mine.width - mineMaximum) < 0.5, "Your message at \(width): \(mine.width)")
            #expect(abs(dock.minX - avatar.minX) < 0.5)
            #expect(abs(dock.width - (width - 48)) < 0.5)
        }
    }

    @Test func readCandidateRequiresEnoughVisibleCommittedContent() {
        let viewport = TranscriptViewport(width: 600, height: 400)
        let frames: [String: TranscriptMessageFrame] = [
            "above": frame(sequence: 11, y: -100, height: 60),
            "visible": frame(sequence: 12, y: 80, height: 60),
            "below": frame(sequence: 99, y: 450, height: 60),
            "optimistic": frame(sequence: 0, y: 200, height: 60)
        ]
        #expect(viewport.readSequence(in: frames) == 12)
        let older: [String: TranscriptMessageFrame] = [
            "older-first": frame(sequence: 281, y: -20, height: 100),
            "older-last": frame(sequence: 282, y: 100, height: 100),
            "later-history": frame(sequence: 456, y: 500, height: 100),
            "newest-request": frame(sequence: 480, y: 800, height: 100)
        ]
        #expect(viewport.readSequence(in: older) == 282)
        #expect(viewport.readSequence(in: ["edge": frame(sequence: 12, y: 390, height: 100)]) == nil)
        #expect(viewport.readSequence(in: ["edge": frame(sequence: 12, y: 376, height: 100)]) == 12)
        #expect(viewport.readSequence(in: ["system": frame(sequence: 7, y: 390, height: 20)]) == 7)
        #expect(viewport.readSequence(in: ["system": frame(sequence: 7, y: 391, height: 20)]) == nil)
        let outside = TranscriptMessageFrame(sequence: 8, rect: CGRect(x: 700, y: 20, width: 80, height: 40),
                                             historyStart: 1)
        #expect(viewport.readSequence(in: ["outside": outside]) == nil)
        #expect(TranscriptViewport().readSequence(in: ["unmeasured": frame(sequence: 8, y: 0, height: 40)]) == nil)
    }

    @Test func pagingAnchorsUseOnlyVisibleCommittedFrames() {
        let viewport = TranscriptViewport(width: 600, height: 400)
        let frames: [String: TranscriptMessageFrame] = [
            "group": frame(sequence: 0, y: -40, height: 200),
            "above": frame(sequence: 280, y: -100, height: 80),
            "first-visible": frame(sequence: 281, y: -20, height: 100),
            "next-visible": frame(sequence: 282, y: 100, height: 100),
            "outside-lane": .init(sequence: 283, rect: CGRect(x: 700, y: -30, width: 100, height: 100),
                                  historyStart: 1)
        ]
        let anchor = viewport.topVisibleFrame(in: frames)
        #expect(anchor?.id == "first-visible")
        #expect(anchor?.frame.rect.minY == -20)
        #expect(TranscriptViewport().topVisibleFrame(in: frames) == nil)
    }

    @Test func theReadingAnchorIsTheFirstRowStartingInTheViewport() {
        let viewport = TranscriptViewport(width: 600, height: 400)
        func row(_ y: CGFloat, _ height: CGFloat, top: CGFloat) -> TranscriptMessageFrame {
            .init(sequence: 1, rect: CGRect(x: 24, y: y, width: 300, height: height), historyStart: 1, contentTop: top)
        }
        let frames = ["spanning": row(-100, 150, top: 900), "first": row(50, 150, top: 1050),
                      "second": row(200, 300, top: 1200), "below": row(420, 80, top: 1420)]
        #expect(viewport.readingAnchor(in: frames) == .init(id: "first", contentTop: 1050))
        // After a scroll down by 60, the first row spans the top and the next one starts in view.
        #expect(viewport.readingAnchor(in: frames, scrolledBy: 60) == .init(id: "second", contentTop: 1200))
        // A row taller than the viewport is the anchor while it fills it.
        #expect(viewport.readingAnchor(in: ["tall": row(-300, 900, top: 600)]) == .init(id: "tall", contentTop: 600))
        #expect(TranscriptViewport().readingAnchor(in: frames) == nil)
    }

    @Test func followingTheBottomSurvivesGrowthUntilTheReaderMovesAway() {
        func viewport(gap: CGFloat, content: CGFloat = 2000) -> TranscriptViewport {
            TranscriptViewport(top: content - 400 - gap, bottomGap: gap, width: 600, height: 400,
                               contentHeight: content)
        }
        let atBottom = viewport(gap: 0)
        // A sent image grows the last bubble while following, then the follow scroll is in flight.
        let grown = viewport(gap: 260, content: 2260)
        #expect(grown.isAtBottom(after: atBottom, wasAtBottom: true, following: true))
        #expect(viewport(gap: 120, content: 2260).isAtBottom(after: grown, wasAtBottom: true, following: false))
        // Jump to Latest that lands short still follows the correction that comes next.
        #expect(viewport(gap: 90).isAtBottom(after: viewport(gap: 900), wasAtBottom: true, following: false))
        // Scrolling, paging or revealing away from the bottom stops following.
        #expect(!viewport(gap: 60).isAtBottom(after: viewport(gap: 30), wasAtBottom: true, following: false))
        #expect(!grown.isAtBottom(after: atBottom, wasAtBottom: true, following: false))
        // Moving toward the bottom resumes following only once it is reached.
        #expect(!viewport(gap: 200).isAtBottom(after: viewport(gap: 600), wasAtBottom: false, following: false))
        #expect(viewport(gap: 40).isAtBottom(after: viewport(gap: 200), wasAtBottom: false, following: false))
    }

    @Test func aResizeBeforeAJumpAppliesCannotPinTheTranscriptBackToLatest() {
        func viewport(top: CGFloat, content: CGFloat) -> TranscriptViewport {
            TranscriptViewport(top: top, bottomGap: content - top - 400, width: 600, height: 400,
                               contentHeight: content)
        }
        let atBottom = viewport(top: 365, content: 765)
        // An image settles while the jump to the start is still queued.
        let resized = viewport(top: 365, content: 772)
        let held = resized.update(after: atBottom, wasAtBottom: true, canFollow: true, isJumping: true)
        #expect(held == .init(isAtBottom: true, follow: .jump, landsJump: false))
        #expect(resized.update(after: atBottom, wasAtBottom: true, canFollow: true, isJumping: false)
                == .init(isAtBottom: true, follow: .latest, landsJump: false))

        // The jump lands, even alongside another resize, and leaves the bottom without following.
        let start = viewport(top: 0, content: 780)
        #expect(start.update(after: resized, wasAtBottom: true, canFollow: true, isJumping: true)
                == .init(isAtBottom: false, follow: nil, landsJump: true))
        // Once landed, later growth below no longer follows.
        #expect(viewport(top: 0, content: 800).update(after: start, wasAtBottom: false, canFollow: true,
                                                      isJumping: false)
                == .init(isAtBottom: false, follow: nil, landsJump: false))
        // A target already on the last screen clamps to the bottom, which keeps following.
        #expect(viewport(top: 372, content: 772).update(after: resized, wasAtBottom: true, canFollow: true,
                                                        isJumping: true)
                == .init(isAtBottom: true, follow: nil, landsJump: true))
        // Before landing, or while the reader scrolls, nothing follows.
        #expect(resized.update(after: atBottom, wasAtBottom: true, canFollow: false, isJumping: true)
                == .init(isAtBottom: true, follow: nil, landsJump: false))
    }

    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled), arguments: [false, true])
    func arrivalsFollowAtTheBottomAndJumpingBackFollowsASend(legacyScrollers: Bool) async throws {
        let openingGaps = TranscriptGapLog()
        let harness = try await TranscriptHarness(messages: (1...30).map(transcriptTestMessage),
                                                  legacyScrollers: legacyScrollers) { harness in
            if harness.capture.hasLanded, harness.scrollView.documentView != nil {
                openingGaps.values.append(harness.bottomGap)
            }
        }
        defer { harness.close() }
        try #require(!openingGaps.values.isEmpty)
        #expect(openingGaps.values.allSatisfy { abs($0) < 2 }, "Opening gaps: \(openingGaps.values)")

        harness.push(transcriptTestMessage(31), revision: 2)
        try await harness.waitUntil { harness.capture.frames["m31"] != nil }
        try await harness.settled()
        #expect(abs(harness.bottomGap) < 2)
        #expect(harness.isVisible("m31"))

        // A reader who scrolled up keeps their place while the conversation continues below.
        try await harness.scrollUp(byWheel: TranscriptHarness.wheelEventsApply) { harness.bottomGap > 400 }
        let origin = harness.scrollView.contentView.bounds.minY
        let reading = harness.visibleFrames()
        try #require(reading.count >= 3)
        harness.push(transcriptTestMessage(32), revision: 3)
        try await harness.waitUntil { harness.store.state?.messages.last?.sequence == 32 }
        try await harness.settled()
        #expect(abs(harness.scrollView.contentView.bounds.minY - origin) < 1)
        for (id, rect) in reading {
            let after = harness.capture.frames[id]?.rect ?? .null
            #expect(abs(after.minY - rect.minY) < 1, "\(id) moved from \(rect) to \(after)")
        }
        #expect(!harness.isVisible("m32"))

        let gaps = TranscriptGapLog()
        let clip = harness.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
            MainActor.assumeIsolated { gaps.values.append(harness.bottomGap) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        harness.interaction.jumpToLatest()
        _ = try? await harness.store.post(id: UUID().uuidString, content: "Sent while scrolled up", attachments: [])
        #expect(harness.store.sendAttempts.first?.error != nil)
        try await harness.waitUntil { abs(harness.bottomGap) < 2 }
        try await harness.settled()
        let landed = try #require(gaps.values.firstIndex { abs($0) < 2 })
        #expect(gaps.values[landed...].allSatisfy { $0 <= 48 }, "Gaps after the jump: \(gaps.values[landed...])")
        #expect(abs(harness.bottomGap) < 2)
        #expect(harness.readRequests == 0)
    }

    /// Thirty unread messages, each its own row, run well past one screen, so the first opens at the
    /// top. One run of five fits on the last screen, so the transcript opens at the bottom with it in
    /// view. A summary card above the first unread message then grows downward from where it's drawn.
    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled), arguments: [false, true], [false, true])
    func aLoadedChannelFirstDrawsItsFirstUnreadMessageWhereItLands(opensAtBottom: Bool, summarizes: Bool)
        async throws {
        let latest = opensAtBottom ? 35 : 60
        let messages = (1...latest).map {
            opensAtBottom && $0 > 30 ? catchUpTestMessage($0, repeats: 3)
                : catchUpTestMessage($0, sender: $0.isMultiple(of: 2) ? .user : .agent("lead"))
        }
        let ready = CatchUp(needsYou: nil, changes: (31...33).map {
            .init(text: "Update \($0) moved along, with enough detail to wrap the line.", sources: [$0])
        }, through: latest)
        let service = summarizes ? StubChannelIntelligence(results: [.ready(ready)], holdsCatchUp: true)
            : StubChannelIntelligence(availability: .unavailable(.deviceNotEligible))
        let log = TranscriptOpeningLog()
        let harness = try await TranscriptHarness(messages: messages, seenThrough: 30,
                                                  height: opensAtBottom ? 1100 : 480, warm: true,
                                                  intelligence: service) { harness in
            guard !harness.capture.frames.isEmpty else { return }
            if harness.rowsOpacity > 0 {
                log.drawn.append(harness.capture.frames["divider-m31"]?.rect)
            } else {
                log.hiddenTurns += 1
            }
        }
        defer {
            service.releaseCatchUp()
            harness.close()
        }
        try await harness.waitUntil { !log.drawn.isEmpty }
        try await harness.settled()

        #expect(log.hiddenTurns > 0)
        let first = try #require(log.drawn.first ?? nil, "The first frame drawn has no divider")
        if !opensAtBottom {
            #expect(first.minY >= -0.5 && first.minY < 120, "The first frame drew the divider at \(first)")
        } else {
            #expect(first.minY >= -0.5 && harness.isVisible("divider-m31") && abs(harness.bottomGap) < 2,
                    "The first frame drew the divider at \(first)")
        }
        if summarizes {
            #expect(service.catchUpCount == 1)
            service.releaseCatchUp()
            try await harness.waitUntil { (harness.capture.frames["divider-m31"]?.rect.height ?? 0) > first.height + 40 }
            try await harness.settled()
        }
        #expect(log.drawn.allSatisfy { $0.map { abs($0.minY - first.minY) < 0.5 } == true },
                "The divider moved after the first frame: \(log.drawn.map { $0?.minY })")
        #expect(harness.readRequests == 0)

        harness.interaction.jumpToLatest()
        try await harness.waitUntil { abs(harness.bottomGap) < 2 }
    }

    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled), arguments: [false, true])
    func resizingKeepsTheBottomOrTheReadersPlace(atBottom: Bool) async throws {
        let harness = try await TranscriptHarness(messages: (1...40).map(transcriptTestMessage), resizable: true)
        defer { harness.close() }

        if !atBottom {
            try await harness.scrollUp(byWheel: TranscriptHarness.wheelEventsApply) { harness.bottomGap > 400 }
            let reading = harness.visibleFrames()
            try #require(reading.count >= 3)
            for height in transcriptResizeSteps(by: 8, count: 20) {
                harness.resize(height: height)
                try await harness.frame()
            }
            try await harness.settled()
            for (id, rect) in reading {
                let after = harness.capture.frames[id]?.rect ?? .null
                #expect(abs(after.minY - rect.minY) < 1, "\(id) moved from \(rect) to \(after)")
            }
            #expect(harness.bottomGap > 300)
            #expect(harness.readRequests == 0)
            return
        }
        // One size per display frame, as a live resize does: taller and back, shorter and back, then a zoom.
        let steps: [CGFloat] = transcriptResizeSteps(by: 8, count: 30) + transcriptResizeSteps(by: -8, count: 20)
            + [900, 480]
        var gaps: [(size: CGSize, drawn: CGFloat, nextFrame: CGFloat)] = []
        func step(width: CGFloat = 520, height: CGFloat = 480) async throws {
            harness.resize(width: width, height: height)
            let drawn = harness.bottomGap
            try await harness.frame()
            gaps.append((CGSize(width: width, height: height), drawn, harness.bottomGap))
        }
        for height in steps { try await step(height: height) }
        // Narrowing rewraps every message, so the content grows in the same pass as the window shrinks.
        for width in transcriptResizeSteps(by: -8, count: 20).map({ $0 + 40 }) { try await step(width: width) }
        for width in [360, 760, 520] as [CGFloat] { try await step(width: width, height: 600) }
        let worst = gaps.max { max(abs($0.drawn), abs($0.nextFrame)) < max(abs($1.drawn), abs($1.nextFrame)) }
        #expect(gaps.allSatisfy { abs($0.drawn) < 1 && abs($0.nextFrame) < 1 },
                "Worst step: \(String(describing: worst))")
        #expect(harness.readRequests == 0)
    }

    @MainActor
    @Test(arguments: [false, true])
    func openingAndClosingFindLeaveTheReadersMessagesInPlace(atBottom: Bool) async throws {
        let find = TranscriptFind()
        let harness = try await TranscriptHarness(messages: transcriptFindTestMessages(1...90), find: find)
        defer { harness.close() }
        try #require(harness.visibleWindowFrames()["m90"] != nil)
        if !atBottom {
            let clip = harness.scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY - 600))
            harness.scrollView.reflectScrolledClipView(clip)
            try await harness.settled()
        }
        let reading = harness.visibleWindowFrames()
        try #require(reading.count >= 3)
        harness.interaction.findInChannel()
        try await harness.waitUntil { find.isPresented && harness.findField != nil }
        try await harness.settled()
        for (id, rect) in reading {
            let after = harness.windowFrames[id] ?? .null
            #expect(abs(after.minY - rect.minY) < 0.5, "Opening moved \(id) from \(rect) to \(after)")
        }
        find.close()
        try await harness.settled()
        for (id, rect) in reading {
            let after = harness.windowFrames[id] ?? .null
            #expect(abs(after.minY - rect.minY) < 0.5, "Closing moved \(id) from \(rect) to \(after)")
        }
    }

    @MainActor
    @Test(arguments: [false, true])
    func findProgressAndErrorsLeaveTheReadersMessagesInPlace(atBottom: Bool) async throws {
        let find = TranscriptFind()
        let messages = transcriptFindTestMessages(61...90)
        let harness = try await TranscriptHarness(messages: messages,
                                                  history: (1...60).map(transcriptTestMessage),
                                                  holdsHistory: true, find: find)
        defer { harness.close() }
        if !atBottom {
            let clip = harness.scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY - 600))
            harness.scrollView.reflectScrolledClipView(clip)
            try await harness.settled()
        }
        try #require(harness.visibleWindowFrames().count >= 3)
        harness.interaction.findInChannel()
        try await harness.waitUntil { find.isPresented && harness.findField != nil }
        try await harness.settled()
        let reading = harness.visibleWindowFrames()
        try #require(reading.count >= 3)

        find.query = "unmatched-find-progress"
        try await harness.waitUntil { find.isSearching }
        try await harness.settled()
        for (id, rect) in reading {
            let after = harness.windowFrames[id] ?? .null
            #expect(abs(after.minY - rect.minY) < 0.5, "Progress moved \(id) from \(rect) to \(after)")
        }
        await find.searchOlder { _ in throw ChannelAPIError.http(status: 503, message: "Unavailable") }
        try #require(find.error != nil)
        try await harness.settled()
        for (id, rect) in reading {
            let after = harness.windowFrames[id] ?? .null
            #expect(abs(after.minY - rect.minY) < 0.5, "Error moved \(id) from \(rect) to \(after)")
        }
        find.query = ""
        try await harness.settled()
        for (id, rect) in reading {
            let after = harness.windowFrames[id] ?? .null
            #expect(abs(after.minY - rect.minY) < 0.5, "Clearing moved \(id) from \(rect) to \(after)")
        }
        #expect(harness.readRequests == 0)
    }

    @MainActor
    @Test func findKeepsOwnershipOfTheReadingPositionWhenMessagesArrive() async throws {
        let find = TranscriptFind()
        let harness = try await TranscriptHarness(messages: transcriptFindTestMessages(1...90), find: find)
        defer { harness.close() }
        harness.interaction.findInChannel()
        try await harness.waitUntil { find.isPresented && harness.findField != nil }
        try await harness.settled()
        let reading = harness.visibleWindowFrames()
        try #require(reading["m90"] != nil)
        try #require(reading.count >= 3)
        harness.push(transcriptTestMessage(91), revision: 2)
        try await harness.waitUntil { harness.store.messages.last?.sequence == 91 }
        try await harness.settled()
        for (id, rect) in reading {
            let after = harness.windowFrames[id] ?? .null
            #expect(abs(after.minY - rect.minY) < 0.5, "Arrival moved \(id) from \(rect) to \(after)")
        }
        #expect(harness.readRequests == 0)
        harness.interaction.jumpToLatest()
        try await harness.waitUntil { !find.blocksRead && abs(harness.bottomGap) < 2 }
    }

    @MainActor
    @Test(arguments: [false, true])
    func artifactViewerSuppressesFindUntilTheTranscriptIsVisible(startsOpen: Bool) async throws {
        let find = TranscriptFind()
        let harness = try await TranscriptHarness(messages: (1...30).map(transcriptTestMessage), find: find)
        defer { harness.close() }
        if startsOpen {
            harness.interaction.findInChannel()
            try await harness.waitUntil { find.isPresented && harness.findField != nil }
        }
        try await harness.settled()
        let revealToken = harness.interaction.revealRequestToken
        harness.interaction.isArtifactViewerPresented = true
        try await harness.waitUntil { !find.isPresented && harness.findField == nil }
        harness.interaction.findInChannel()
        harness.interaction.findNext(1)
        try await harness.settled()
        #expect(!find.isPresented && harness.findField == nil)
        #expect(harness.interaction.revealRequestToken == revealToken)
        #expect(harness.readRequests == 0)

        harness.interaction.isArtifactViewerPresented = false
        harness.interaction.findInChannel()
        try await harness.waitUntil { find.isPresented && harness.findField != nil }
    }

    @MainActor
    @Test func closingFindAtTheBottomRestoresFollowingButKeepsReadSuspended() async throws {
        let find = TranscriptFind()
        let harness = try await TranscriptHarness(messages: transcriptFindTestMessages(1...90), find: find)
        defer { harness.close() }
        try #require(harness.visibleWindowFrames()["m90"] != nil)
        harness.interaction.findInChannel()
        try await harness.waitUntil { find.isPresented && harness.findField != nil }
        find.close()
        try await harness.settled()
        #expect(find.blocksRead && !find.isPresented)
        harness.push(transcriptTestMessage(91), revision: 2)
        try await harness.waitUntil { harness.store.messages.last?.sequence == 91 && abs(harness.bottomGap) < 2 }
        #expect(find.blocksRead && harness.readRequests == 0)
    }

    @MainActor
    @Test(arguments: [false, true])
    func clearingFindKeepsRevealedMembershipLinesAndTheReadersPlace(closes: Bool) async throws {
        let memberships = (1...8).map { sequence in
            ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T12:00:00Z",
                           sender: .system, content: .system(.init(type: "member_joined",
                               member: .init(id: "member\(sequence)", name: "Member \(sequence)"))))
        }
        let messages = memberships + transcriptFindTestMessages(9...30)
        let find = TranscriptFind()
        let harness = try await TranscriptHarness(messages: messages, find: find)
        defer { harness.close() }
        harness.interaction.findInChannel()
        try await harness.waitUntil { find.isPresented && harness.findField != nil }
        find.query = "joined"
        try await harness.waitUntil { memberships.allSatisfy { harness.capture.frames[$0.id]?.sequence == $0.sequence } }
        try await harness.settled()
        let reading = harness.visibleWindowFrames()
        try #require(reading.count >= 3)
        let first = try #require(harness.windowFrames["m1"])
        #expect(first.minY >= 57, "The oldest matching line is hidden beneath Find's status row: \(first)")
        if closes { find.close() } else { find.query = "" }
        try await harness.settled()
        for (id, rect) in reading {
            let after = harness.windowFrames[id] ?? .null
            #expect(abs(after.minY - rect.minY) < 0.5, "Clearing Find moved \(id) from \(rect) to \(after)")
        }
        #expect(find.highlights.isEmpty)
        #expect(memberships.allSatisfy { harness.capture.frames[$0.id]?.sequence == $0.sequence })
        #expect(harness.readRequests == 0)
    }

    @MainActor
    // Quarantined after main CI 40148398608 failed on README-only 43d015a, with no identified code cause.
    // History reached sequence 1, but m2 stayed offscreen: landed true, gap 2914,
    // clip (0, 1890, 503, 480), document (0, 0, 503, 5148).
    // Owner: Transcript. Follow-up t255: diagnose older-match reveal and add deterministic coverage.
    // The merge gate now covers unmeasured, stale and shifting reveal layouts with deterministic inputs.
    // Opt in with TOY_BOX_TEST_OLDER_FIND_REVEAL=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOY_BOX_TEST_OLDER_FIND_REVEAL"] == "1"))
    func findingOlderMessagesDoesNotPageTheTranscriptUntilNavigation() async throws {
        var history = (1...60).map(transcriptTestMessage)
        history[1].content = .text("An older-only targetneedle for Find.")
        history[1].sender = .agent("helper")
        let find = TranscriptFind()
        let harness = try await TranscriptHarness(messages: (61...90).map(transcriptTestMessage),
                                                  history: history, find: find)
        defer { harness.close() }
        harness.interaction.messageView = .yours
        harness.interaction.findInChannel()
        func searchField(in view: NSView) -> NSSearchField? {
            view as? NSSearchField ?? view.subviews.lazy.compactMap(searchField(in:)).first
        }
        try await harness.waitUntil { harness.scrollView.window?.contentView.flatMap(searchField(in:)) != nil }
        let field = try #require(harness.scrollView.window?.contentView.flatMap(searchField(in:)))
        field.stringValue = "targetneedle"
        NSApp.sendAction(try #require(field.action), to: field.target, from: field)
        try await harness.waitUntil { !find.isSearching && find.countLabel == "1 of 1" }
        try await harness.settled()
        #expect(harness.store.messages.map(\.sequence) == Array(61...90))
        #expect(harness.readRequests == 0)

        harness.interaction.findNext(1)
        try await harness.waitUntil { harness.store.messages.first?.sequence == 1 && harness.isVisible("m2") }
        #expect(harness.interaction.messageView == .all)
        #expect(harness.readRequests == 0)
    }

    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func scrollingIntoOlderHistoryKeepsTheReaderInPlace() async throws {
        let harness = try await TranscriptHarness(messages: (61...90).map(transcriptTestMessage),
                                                  history: (1...60).map(transcriptTestMessage),
                                                  holdsHistory: true)
        defer { harness.close() }

        let wheel = TranscriptHarness.wheelEventsApply
        for (oldest, keepsScrolling) in [(31, true), (1, false)] {
            try await harness.scrollUp(byWheel: wheel) { harness.store.isLoadingOlder }
            if keepsScrolling {
                // A new scroll while the page loads, like one the triggering notch starts late, moves
                // the place to keep rather than abandoning it.
                let origin = harness.scrollView.contentView.bounds.minY
                try await harness.scrollDown(byWheel: wheel) {
                    harness.scrollView.contentView.bounds.minY > origin + 40
                }
            }
            let reading = harness.visibleFrames()
            try #require(reading.count >= 3)
            harness.releaseHistory()
            try await harness.waitUntil {
                harness.store.state?.messages.first?.sequence == oldest && !harness.store.isLoadingOlder
            }
            try await harness.waitUntil {
                !harness.capture.isRestoringHistory && reading.allSatisfy { id, rect in
                    guard let restored = harness.frames[id], restored.historyStart == oldest else { return false }
                    return abs(restored.rect.maxY - rect.maxY) < 1
                }
            }
            try await harness.settled()
            for (id, rect) in reading {
                let after = harness.frames[id]?.rect ?? .null
                #expect(abs(after.maxY - rect.maxY) < 1, "Page from \(oldest): \(id) moved from \(rect) to \(after)")
                if id == "m\(oldest + 30)" {
                    // The page's last message has the same sender, so this row joins its run and drops
                    // only the header above its text.
                    #expect(after.height < rect.height - 10)
                } else {
                    #expect(abs(after.minY - rect.minY) < 1, "Page from \(oldest): \(id) moved from \(rect) to \(after)")
                }
            }
            #expect(harness.scrollView.contentView.bounds.minY > 400)
        }
        #expect(!harness.store.hasOlderMessages)
        #expect(harness.readRequests == 0)
    }

    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func floatingBarsBoundTheReadViewportAndBottomDistance() async throws {
        let capture = TranscriptLayoutCapture()
        let view = NSHostingView(rootView:
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(1...40, id: \.self) { sequence in
                            Color.clear.frame(height: 40)
                                .transcriptMessageFrame(id: "m\(sequence)", sequence: sequence, historyStart: 1)
                                .id(sequence)
                        }
                    }
                }
                .coordinateSpace(name: "transcript-viewport")
                .onScrollGeometryChange(for: TranscriptViewport.self) { TranscriptViewport($0) } action: {
                    capture.viewport = $1
                }
                .onPreferenceChange(TranscriptMessageFrames.self) { capture.frames = $0 }
                .safeAreaBar(edge: .top, spacing: 0) { Color.clear.frame(height: 50) }
                .safeAreaBar(edge: .bottom, spacing: 0) { Color.clear.frame(height: 100) }
                .onAppear { capture.proxy = proxy }
            }
            .frame(width: 400, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        func settle() async throws {
            try await transcriptSettled(in: view) { capture.viewport }
        }
        try await settle()
        let proxy = try #require(capture.proxy)

        proxy.scrollTo(40, anchor: .bottom)
        try await settle()
        #expect(abs(capture.viewport.height - 450) < 0.5)
        #expect(capture.viewport.bottomGap < 0.5)
        #expect(abs(try #require(capture.frames["m40"]).rect.maxY - 450) < 0.5)
        #expect(capture.viewport.readSequence(in: capture.frames) == 40)

        // Three rows sit beneath the bottom bar. They stay unread and still count as distance from the end.
        proxy.scrollTo(37, anchor: .bottom)
        try await settle()
        #expect(abs(capture.viewport.bottomGap - 120) < 0.5)
        #expect(capture.viewport.readSequence(in: capture.frames) == 37)

        // A row tucked under the toolbar is neither the paging anchor nor the read edge.
        proxy.scrollTo(10, anchor: .top)
        try await settle()
        #expect(abs(try #require(capture.frames["m10"]).rect.minY) < 0.5)
        #expect(capture.viewport.topVisibleFrame(in: capture.frames)?.id == "m10")
        #expect(capture.viewport.readSequence(in: capture.frames) == 20)
    }

    @Test func requestAnnouncementsSkipInitialStateAndAnnounceNewSequencesOnce() {
        var announcements = TranscriptRequestAnnouncements()
        let updates: [(Int?, Bool)] = [
            (480, false), (481, true), (481, false), (nil, false),
            (481, false), (479, false), (482, true)
        ]
        for (sequence, expected) in updates {
            let announced = announcements.receive(sequence, isEligible: true)
            #expect(announced == expected)
        }
        announcements = TranscriptRequestAnnouncements()
        let activation: [(Int?, Bool, Bool)] = [
            (nil, false, false), (10, false, false), (10, true, false), (11, true, true)
        ]
        for (sequence, eligible, expected) in activation {
            let announced = announcements.receive(sequence, isEligible: eligible)
            #expect(announced == expected)
        }
    }

    @MainActor
    @Test func consumingARevealDoesNotCancelItOrReplayItWhenTheTranscriptReopens() throws {
        let interaction = ChannelInteraction()
        interaction.reveal(sequence: 12)
        let first = try #require(interaction.revealRequest)
        interaction.consumeRevealRequest(first.token)
        #expect(interaction.revealRequest == nil)
        #expect(interaction.revealRequestToken == first.token)
        interaction.reveal(sequence: 25)
        interaction.consumeRevealRequest(first.token)
        #expect(interaction.revealRequest?.sequence == 25)
        #expect(interaction.revealRequestToken != first.token)
    }

    @Test func thumbnailsFitTheirBoundsWithoutCroppingOrUpscaling() {
        #expect(transcriptThumbnailSize(CGSize(width: 1200, height: 600)) == CGSize(width: 240, height: 120))
        #expect(transcriptThumbnailSize(CGSize(width: 600, height: 1200)) == CGSize(width: 80, height: 160))
        #expect(transcriptThumbnailSize(CGSize(width: 1, height: 1)) == CGSize(width: 1, height: 1))
        #expect(transcriptThumbnailSize(.zero) == CGSize(width: 44, height: 44))
    }

    @Test func inlineImageSizesComeFromTheHeaderWithoutDecodingThePayload() throws {
        // Noise keeps the PNG large, so the probe has to stop well short of the payload's end.
        let large = try encodedImage(width: 900, height: 600, type: .png)
        #expect(large.count > 500_000)
        #expect(TranscriptThumbnails.headerPixelSize(base64: large) == CGSize(width: 900, height: 600))
        // EXIF orientation 6 is a quarter turn, which the decoded thumbnail applies too.
        let rotated = try encodedImage(width: 400, height: 200, type: .jpeg, orientation: 6)
        #expect(TranscriptThumbnails.headerPixelSize(base64: rotated) == CGSize(width: 200, height: 400))
        #expect(TranscriptThumbnails.headerPixelSize(base64: "bm90IGFuIGltYWdl") == nil)
        #expect(TranscriptThumbnails.headerPixelSize(base64: "%%%") == nil)
    }

    @MainActor
    @Test func imageHeadersGiveInlineAndCachedImagesTheirFinalSizeOnTheFirstPass() throws {
        let payload = try encodedImage(width: 600, height: 300, type: .png)
        let attachment = ChannelAttachment(name: "wide.png", mimeType: "image/png", base64: payload)
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        #expect(TranscriptThumbnails.remembered(for: attachment, api: api) == nil)
        let view = NSHostingView(rootView: TranscriptAttachments(attachments: [attachment], api: api)
            .fixedSize())
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize == CGSize(width: 240, height: 120))
        do {
            // Every test process shares the cache folder, so each run uses its own path.
            let remote = ChannelAttachment(name: "wide.png", url: "/files/\(UUID().uuidString).png",
                                           mimeType: "image/png")
            #expect(TranscriptThumbnails.pixelSize(for: remote, api: api) == nil)
            let file = try #require(TranscriptAttachmentCache.destination(for: remote, api: api))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try #require(Data(base64Encoded: payload)).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(TranscriptThumbnails.pixelSize(for: remote, api: api) == CGSize(width: 600, height: 300))
            let cached = NSHostingView(rootView: TranscriptAttachments(attachments: [remote], api: api).fixedSize())
            cached.layoutSubtreeIfNeeded()
            #expect(cached.fittingSize == CGSize(width: 240, height: 120))
        }
    }

    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func imageFilmstripHasNoCaptionHeightAndDoesNotStackAtNarrowWidths() async throws {
        let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let image = try #require(context.makeImage())
        let payload = try encodedImage(width: 120, height: 80, type: .png)
        let attachments = ["A long image filename.png", "Another image.png"].map {
            ChannelAttachment(name: $0, mimeType: "image/png", base64: payload)
        }
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        for attachment in attachments {
            let thumbnail = TranscriptThumbnails.remember(image, for: attachment, api: api)
            #expect(thumbnail.size == CGSize(width: 120, height: 80))
        }

        for width: CGFloat in [160, 328] {
            let capture = TranscriptLayoutCapture()
            let view = NSHostingView(rootView:
                TranscriptAttachments(attachments: attachments, api: api, alignment: .trailing)
                    .transcriptMessageFrame(id: "strip", sequence: 1, historyStart: 1)
                    .frame(width: width, alignment: .trailing)
                    .coordinateSpace(name: "transcript-viewport")
                    .onPreferenceChange(TranscriptMessageFrames.self) { capture.frames = $0 }
                    .fixedSize(horizontal: false, vertical: true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(abs(view.fittingSize.height - 80) < 0.5, "\(scrollGeometry(in: view, width: width))")
            #expect(abs(view.fittingSize.width - width) < 0.5)
            let strip = try #require(capture.frames["strip"]).rect
            #expect(abs(strip.width - width) < 0.5)
            #expect(abs(strip.maxX - width) < 0.5)
        }
    }

    /// The measured size and every scroll view's geometry, for a failure on another machine.
    @MainActor
    private func scrollGeometry(in view: NSView, width: CGFloat) -> String {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scrollers = NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay"
        let scale = view.window?.backingScaleFactor ?? 0
        let scrollViews = descendants(view).compactMap { $0 as? NSScrollView }.map { scrollView in
            let style = scrollView.scrollerStyle == .legacy ? "legacy" : "overlay"
            let horizontal = scrollView.hasHorizontalScroller
                ? "\(scrollView.horizontalScroller?.frame ?? .zero)\(scrollView.horizontalScroller?.isHidden == true ? " hidden" : "")"
                : "none"
            return "\(scrollView.frame) \(style), content \(scrollView.contentView.frame), document "
                + "\(scrollView.documentView?.frame ?? .zero), horizontal scroller \(horizontal)"
        }
        return "\(view.fittingSize) at \(width) wide, \(scale)x, \(scrollers) scrollers. Scroll views: \(scrollViews)"
    }

    @MainActor
    @Test func artifactSharesStayInlineWhenTheyFitAndKeepIndividualReadFrames() async throws {
        let wide = try await artifactShareLayout(width: 600, titles: ["Build notes", "Design direction"])
        let narrow = try await artifactShareLayout(width: 160, titles: ["Build notes", "Design direction"])
        let first = try #require(wide.frames["share-1"])
        let second = try #require(wide.frames["share-2"])
        #expect(abs(first.rect.minY - second.rect.minY) < 1)
        #expect(second.rect.minX > first.rect.maxX)
        #expect(first.sequence == 1 && second.sequence == 2)
        #expect(first.historyStart == 1 && second.historyStart == 1)
        #expect(narrow.height > wide.height + 12)
        let narrowFirst = try #require(narrow.frames["share-1"])
        let narrowSecond = try #require(narrow.frames["share-2"])
        #expect(narrowSecond.rect.minY >= narrowFirst.rect.maxY)
        #expect(narrow.frames.count == 2)
        let layout = try await artifactShareLayout(
            width: 160, titles: ["Implementation direction and detailed reading experience notes"])
        let title = try #require(layout.frames["share-1"])
        #expect(title.rect.width <= 160)
        #expect(title.rect.height > 24)
    }

    @Test func artifactShareJoinersMatchThePane() {
        func sentence(_ titles: [String]) -> String {
            titles.indices.map { index in
                let joiners = transcriptListJoiners(index: index, count: titles.count)
                return [joiners.before, titles[index] + (joiners.after ?? "")]
                    .compactMap { $0 }.joined(separator: " ")
            }.joined(separator: " ")
        }
        #expect(sentence(["Notes"]) == "Notes")
        #expect(sentence(["Notes", "Plan"]) == "Notes and Plan")
        #expect(sentence(["Notes", "Plan", "Spec"]) == "Notes, Plan, and Spec")
    }

    @Test func consecutiveSystemRowsStackAsOneGroupUntilADividerOrMessage() throws {
        func message(_ sequence: Int, day: Int = 1, system kind: String? = nil) -> ChannelMessage {
            ChannelMessage(id: "m\(sequence)", sequence: sequence,
                           timestamp: String(format: "2026-10-%02dT10:%02d:00Z", day, sequence),
                           sender: kind == nil ? .agent("lead") : .system,
                           content: kind.map { .system(.init(type: $0)) } ?? .text("Progress"))
        }
        let rows = transcriptRows([
            message(1), message(2, system: "member_joined"), message(3, system: "member_left"),
            message(4, day: 2, system: "tasks_completed"), message(5, day: 2, system: "channel_renamed"),
            message(6, day: 2), message(7, day: 2, system: "tasks_completed"),
        ], lead: .lead(id: "lead"), members: [])
        try #require(rows.count == 7)
        #expect(rows[3].divider?.day != nil)
        #expect(transcriptStackedSystemRowIDs(rows) == [rows[2].id, rows[4].id])
    }

    @Test func coincidingDayAndUnreadDividersReadAsOneHeader() throws {
        func message(_ sequence: Int, day: Int) -> ChannelMessage {
            ChannelMessage(id: "m\(sequence)", sequence: sequence,
                           timestamp: String(format: "2026-10-%02dT10:00:00Z", day),
                           sender: .agent("lead"), content: .text("Progress"))
        }
        let rows = transcriptRows([message(1, day: 1), message(2, day: 2)],
                                  lead: .lead(id: "lead"), members: [], unreadAfter: 1)
        let divider = try #require(rows.last?.divider)
        let day = try #require(divider.day)
        #expect(transcriptDividerAccessibilityLabel(divider, now: day) == "Today, New messages")
    }

    @MainActor
    @Test func centeredFlowCentersEachLineAndWrapsWholeItems() async throws {
        let capture = TranscriptLayoutCapture()
        let view = NSHostingView(rootView:
            TranscriptCenteredFlow(spacing: 4, lineSpacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Color.clear.frame(width: 100, height: 10)
                        .transcriptMessageFrame(id: "item-\(index)", sequence: index + 1, historyStart: 1)
                }
            }
            .frame(width: 250)
            .coordinateSpace(name: "transcript-viewport")
            .onPreferenceChange(TranscriptMessageFrames.self) { capture.frames = $0 })
        view.frame = NSRect(x: 0, y: 0, width: 250, height: 100)
        try await transcriptUntil(in: view) { capture.frames.count == 3 }
        let first = try #require(capture.frames["item-0"]?.rect)
        let second = try #require(capture.frames["item-1"]?.rect)
        let third = try #require(capture.frames["item-2"]?.rect)
        #expect(abs(first.minX - 23) < 0.5 && abs(second.minX - 127) < 0.5)
        #expect(abs(first.minY - second.minY) < 0.5)
        #expect(abs(third.minX - 75) < 0.5)
        #expect(abs(third.minY - (first.maxY + 2)) < 0.5)
    }

    @MainActor
    @Test(.enabled(if: transcriptTimingTestsEnabled))
    func systemLinksAcceptClicksWithinATwentyEightPointTarget() async throws {
        var opened = 0
        let capture = TranscriptLayoutCapture()
        let message = ChannelMessage(id: "share-1", sequence: 1, timestamp: "2026-10-22T12:00:00Z",
                                     sender: .init(type: "system"),
                                     content: .system(.init(type: "artifact_shared",
                                                            artifact: .init(id: "artifact",
                                                                            file: .init(kind: "machine", path: "/notes.md"),
                                                                            title: "Build notes"))))
        let view = NSHostingView(rootView:
            TranscriptArtifactShares(actorName: "Lead", messages: [message], historyStart: 1,
                                     onOpen: { _ in opened += 1 })
                .font(.system(size: 11))
                .frame(width: 300, height: 80)
                .coordinateSpace(name: "transcript-viewport")
                .onPreferenceChange(TranscriptMessageFrames.self) { capture.frames = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        defer { window.close() }
        try await transcriptUntil(in: view) { capture.frames["share-1"] != nil }
        let link = try #require(capture.frames["share-1"]?.rect)
        #expect(link.height < 20)

        func click(atY y: CGFloat) async throws {
            let point = NSPoint(x: link.midX, y: 80 - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            try await transcriptFrame(in: view)
        }
        try await click(atY: link.midY)
        #expect(opened == 1)
        try await click(atY: link.minY - 6)
        try await click(atY: link.maxY + 6)
        #expect(opened == 3)
        try await click(atY: link.minY - 12)
        #expect(opened == 3)
    }

    @MainActor
    @Test func hoverActionsStayOverAShortBubble() async throws {
        func actionsMinX(bubbleWidth: CGFloat) async throws -> CGFloat {
            let capture = TranscriptLayoutCapture()
            let view = NSHostingView(rootView:
                Color.clear.frame(width: bubbleWidth, height: 40)
                    .overlay {
                        TranscriptHoverActionsLayout {
                            Color.clear.frame(width: 60, height: 24)
                                .transcriptMessageFrame(id: "actions", sequence: 1, historyStart: 1)
                        }
                    }
                    .padding(20)
                    .coordinateSpace(name: "transcript-viewport")
                    .onPreferenceChange(TranscriptMessageFrames.self) { capture.frames = $0 })
            view.frame = NSRect(x: 0, y: 0, width: bubbleWidth + 40, height: 80)
            try await transcriptUntil(in: view) { capture.frames["actions"] != nil }
            let actions = try #require(capture.frames["actions"]?.rect)
            #expect(abs(actions.minY - 8) < 0.5)
            return actions.minX - 20
        }
        #expect(abs(try await actionsMinX(bubbleWidth: 300) - 232) < 0.5)
        #expect(abs(try await actionsMinX(bubbleWidth: 40)) < 0.5)
    }

    @Test func inlineAttachmentsBecomeLocalQuickLookFiles() async throws {
        let data = Data("Quick Look test \(UUID().uuidString)".utf8)
        let attachment = ChannelAttachment(name: "notes.txt", mimeType: "text/plain", base64: data.base64EncodedString())
        let api = try ChannelAPI(serverURL: "http://localhost:3210/prefix")
        let file = try await TranscriptAttachmentCache.shared.file(for: attachment, api: api)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.isFileURL)
        #expect(file.pathExtension == "txt")
        #expect(try Data(contentsOf: file) == data)
        try Data("damaged cache".utf8).write(to: file, options: .atomic)
        let refreshed = try await TranscriptAttachmentCache.shared.file(for: attachment, api: api, reload: true)
        #expect(refreshed == file)
        #expect(try Data(contentsOf: refreshed) == data)
    }

    @Test func unsupportedAddressesAndInvalidInlineDataFailExplicitly() async throws {
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        await #expect(throws: AttachmentError.invalidAddress) {
            try await TranscriptAttachmentCache.shared.file(for: .init(url: "file:///not-a-remote-resource"), api: api)
        }
        await #expect(throws: AttachmentError.invalidData) {
            try await TranscriptAttachmentCache.shared.file(for: .init(base64: "not valid base64!"), api: api)
        }
    }

    private func frame(sequence: Int, y: CGFloat, height: CGFloat) -> TranscriptMessageFrame {
        .init(sequence: sequence, rect: CGRect(x: 24, y: y, width: 300, height: height), historyStart: 1)
    }

    private func encodedImage(width: Int, height: Int, type: UTType, orientation: Int = 1) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let count = width * height * 4
        let words = (0..<((count + 7) / 8)).map { _ in generator.next() }
        let data = words.withUnsafeBytes { Data($0.prefix(count)) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return (encoded as Data).base64EncodedString()
    }

    private func composite(_ color: NSColor, over background: (Double, Double, Double))
        -> (Double, Double, Double) {
        let alpha = color.alphaComponent
        return (color.redComponent * alpha + background.0 * (1 - alpha),
                color.greenComponent * alpha + background.1 * (1 - alpha),
                color.blueComponent * alpha + background.2 * (1 - alpha))
    }

    private func luminance(_ color: (Double, Double, Double)) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.0) + 0.7152 * linear(color.1) + 0.0722 * linear(color.2)
    }

    @MainActor
    private func artifactShareLayout(width: CGFloat, titles: [String]) async throws
        -> (height: CGFloat, frames: [String: TranscriptMessageFrame]) {
        let messages = titles.enumerated().map { index, title in
            ChannelMessage(id: "share-\(index + 1)", sequence: index + 1,
                           timestamp: "2026-10-22T12:00:00Z", sender: .init(type: "system"),
                           content: .system(.init(type: "artifact_shared",
                                                  artifact: .init(id: "artifact-\(index)",
                                                                  file: .init(kind: "machine", path: "/notes-\(index).md"),
                                                                  title: title))))
        }
        let capture = TranscriptLayoutCapture()
        let view = NSHostingView(rootView:
            TranscriptArtifactShares(actorName: "Lead", messages: messages, historyStart: 1, onOpen: { _ in })
                .font(.system(size: 12))
                .coordinateSpace(name: "transcript-viewport")
                .onPreferenceChange(TranscriptMessageFrames.self) { capture.frames = $0 }
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true))
        view.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        try await transcriptUntil(in: view) { capture.frames.count == messages.count }
        return (view.fittingSize.height, capture.frames)
    }

    @MainActor
    @Test(arguments: [CGFloat(16), 20])
    func overlappingAvatarsCutATransparentGapAroundTheFaceInFront(size: CGFloat) async throws {
        let agents = stackTestAgents(["#ff0000", "#0000ff"])
        let bitmap = try await renderedTranscriptBitmap(AgentAvatarStack(agents: agents, size: size),
                                                        size: CGSize(width: size * 2 - 4, height: size))
        let scale = CGFloat(bitmap.pixelsWide) / (size * 2 - 4)
        func color(atX x: CGFloat, y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        }
        // The front face ends at `size`, the next starts 1.5 points later, and nothing is drawn between.
        // Faces are sampled above the mark's center stroke.
        let front = try color(atX: size / 2, y: size * 0.3)
        let gap = try color(atX: size + 0.75, y: size / 2)
        let next = try color(atX: size * 1.5 - 4, y: size * 0.3)
        #expect(front.alphaComponent > 0.95 && front.redComponent - front.blueComponent > 0.4)
        #expect(gap.alphaComponent < 0.1, "Gap alpha \(gap.alphaComponent) at \(size) points")
        #expect(next.alphaComponent > 0.95 && next.blueComponent - next.redComponent > 0.4)
    }

    @MainActor
    @Test func avatarStacksLimitFacesAndOptionallyCountTheRest() {
        let five = stackTestAgents(Array(repeating: "#7fa171", count: 5))
        func width(_ stack: AgentAvatarStack) -> CGFloat { NSHostingView(rootView: stack).fittingSize.width }
        #expect(width(AgentAvatarStack(agents: five, size: 20, limit: 1, showsOverflow: false)) == 20)
        #expect(width(AgentAvatarStack(agents: five, size: 20, showsOverflow: false)) == 52)
        #expect(width(AgentAvatarStack(agents: Array(five.prefix(3)), size: 20)) == 52)
        #expect(width(AgentAvatarStack(agents: five, size: 20, limit: 1)) > 27)
        #expect(width(AgentAvatarStack(agents: five, size: 20)) > 59)
    }

    @MainActor
    @Test func theWorkingCapsuleKeepsTheFirstFaceInFrontWithTheStackGap() async throws {
        let agents = stackTestAgents(["#ff0000", "#0000ff"])
        let state = ChannelState(
            revision: 1,
            channel: Channel(id: "capsule", name: "Capsule", model: .init(provider: "test", name: "test"),
                             latestSequence: 0, seenThrough: 0, updatedAt: "2026-10-22T12:00:00Z"),
            lead: agents[0], members: [agents[1]],
            presence: [agents[0].id: .init(state: "working"), agents[1].id: .init(state: "working")])
        let bitmap = try await renderedTranscriptBitmap(
            TranscriptWorkingRow(agents: state.agents, presence: state.presence)
                .frame(width: 240, height: 28, alignment: .leading),
            size: CGSize(width: 240, height: 28))
        let scale = CGFloat(bitmap.pixelsWide) / 240
        func color(atX x: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(14 * scale))?.usingColorSpace(.sRGB))
        }
        // Faces start inside the capsule's 4-point inset. The first ends at 24 and the gap runs to 25.5.
        let front = try color(atX: 23)
        let gap = try color(atX: 24.75)
        #expect(front.redComponent - front.blueComponent > 0.4)
        #expect(!(gap.alphaComponent > 0.5 && gap.blueComponent - gap.redComponent > 0.4),
                "The second face covers the gap: \(gap)")
    }
}

@Suite("Transcript landing policy")
struct TranscriptLandingTests {
    private func rows(_ range: ClosedRange<Int> = 1...20) -> [TranscriptRow] {
        transcriptRows(range.map {
            catchUpTestMessage($0, sender: $0.isMultiple(of: 2) ? .user : .agent("lead"))
        }, lead: .lead(id: "lead"), members: [])
    }

    private func frame(_ y: CGFloat) -> TranscriptMessageFrame {
        .init(sequence: 1, rect: CGRect(x: 0, y: y, width: 400, height: 40), historyStart: 1)
    }

    private func step(top: CGFloat, height: CGFloat = 400, bottomGap: CGFloat = 100,
                      isColdOpening: Bool = false, jumps: Int = 0, hasPendingJump: Bool = false) -> TranscriptLanding.Step {
        let row = rows()[0]
        return TranscriptLanding.step(
            on: row, frames: [row.messages[0].id: frame(top)],
            viewport: TranscriptViewport(bottomGap: bottomGap, width: 500, height: height),
            isColdOpening: isColdOpening, jumps: jumps, hasPendingJump: hasPendingJump)
    }

    @Test func theTargetIsTheFirstRowContainingUnreadMessagesOrLatest() throws {
        let rows = rows()
        #expect(TranscriptLanding.target(unreadAfter: nil, rows: rows) == .latest)
        #expect(TranscriptLanding.target(unreadAfter: 20, rows: rows) == .latest)
        #expect(TranscriptLanding.target(unreadAfter: 0, rows: []) == .latest)
        #expect(TranscriptLanding.target(unreadAfter: 10, rows: rows) == .unread(rows[10].id))
        let run = transcriptRows((1...10).map(transcriptTestMessage),
                                 lead: .lead(id: "lead"), members: [], unreadAfter: 5)
        let unread = try #require(run.first { $0.messages.contains { $0.sequence == 6 } })
        #expect(TranscriptLanding.target(unreadAfter: 5, rows: run) == .unread(unread.id))
    }

    @Test func aWarmOpeningRequiresTheUnreadBoundaryToBeLoaded() {
        let rows = rows(31...50)
        #expect(TranscriptLanding.opening(unreadAfter: nil, oldestSequence: 31,
                                         hasOlderMessages: true, rows: rows) == nil)
        #expect(TranscriptLanding.opening(unreadAfter: 30, oldestSequence: nil,
                                         hasOlderMessages: true, rows: rows) == nil)
        #expect(TranscriptLanding.opening(unreadAfter: 20, oldestSequence: 31,
                                         hasOlderMessages: true, rows: rows) == nil)
        #expect(TranscriptLanding.opening(unreadAfter: 30, oldestSequence: 31,
                                         hasOlderMessages: true, rows: rows)?.rowID == rows[0].id)
        #expect(TranscriptLanding.opening(unreadAfter: 20, oldestSequence: 31,
                                         hasOlderMessages: false, rows: rows)?.rowID == rows[0].id)
        #expect(TranscriptLanding.opening(unreadAfter: 50, oldestSequence: 31,
                                         hasOlderMessages: false, rows: rows) == nil)
    }

    @Test func aWarmOpeningSeedsOnlyTailsLongerThanEightRows() throws {
        let rows = rows()
        let short = try #require(TranscriptLanding.opening(unreadAfter: 12, oldestSequence: 1,
                                                           hasOlderMessages: false, rows: rows))
        #expect(short == .init(rowID: rows[12].id, unreadAfter: 12, seeds: false))
        let long = try #require(TranscriptLanding.opening(unreadAfter: 11, oldestSequence: 1,
                                                          hasOlderMessages: false, rows: rows))
        #expect(long == .init(rowID: rows[11].id, unreadAfter: 11, seeds: true))
    }

    @Test func aColdOpeningMustTargetUnreadOnceEvenWhenProvisionalFramesLookLanded() {
        #expect(step(top: 132.6857, height: 800, bottomGap: 0, isColdOpening: true) == .placeColdOpening)
        #expect(step(top: 20, isColdOpening: true) == .placeColdOpening)
        #expect(step(top: 20, isColdOpening: true, jumps: 1) == .settled)
        #expect(step(top: 20) == .settled)
    }

    @Test(arguments: [(CGFloat(-0.51), false), (-0.5, true), (0, true), (119.99, true), (120, false)])
    func aTopLandingUsesTheExactVisibleThreshold(_ sample: (top: CGFloat, fits: Bool)) {
        #expect(step(top: sample.top) == (sample.fits ? .settled : .correctPosition))
        #expect(step(top: 49.99, height: 100) == .settled)
        #expect(step(top: 50, height: 100) == .correctPosition)
    }

    @Test func aShortTailMayLandAnywhereInsideTheLastScreenButNotUnderTheFloatingBar() {
        #expect(step(top: 300, bottomGap: 0) == .settled)
        #expect(step(top: 300, bottomGap: 0.99) == .settled)
        #expect(step(top: 300, bottomGap: 1) == .correctPosition)
        #expect(step(top: 400, bottomGap: 0) == .correctPosition)
        #expect(step(top: -0.51, bottomGap: 0) == .correctPosition)
    }

    @Test func placementMeasuresTheMessageRunSystemGroupAndUnreadDivider() {
        let row = rows()[0]
        let viewport = TranscriptViewport(bottomGap: 100, width: 500, height: 400)
        for id in [row.messages[0].id, row.id, "system-group-\(row.id)", "divider-\(row.id)"] {
            #expect(TranscriptLanding.step(on: row, frames: [id: frame(20)], viewport: viewport,
                                            isColdOpening: false, jumps: 0, hasPendingJump: false) == .settled)
        }
        #expect(TranscriptLanding.step(on: row, frames: [:], viewport: viewport,
                                       isColdOpening: false, jumps: 0, hasPendingJump: false) == .correctPosition)
        #expect(step(top: 20, height: 0) == .correctPosition)
        let straddling = [row.messages[0].id: frame(-10), "divider-\(row.id)": frame(20)]
        #expect(TranscriptLanding.step(on: row, frames: straddling, viewport: viewport,
                                       isColdOpening: false, jumps: 0, hasPendingJump: false) == .correctPosition)
    }

    @Test func anInFlightJumpOwnsThePositionAndCorrectionsStayBounded() {
        #expect(step(top: 20, hasPendingJump: true) == .waitForJump)
        #expect(step(top: 20, isColdOpening: true, hasPendingJump: true) == .waitForJump)
        #expect(step(top: 500, jumps: 1) == .correctPosition)
        #expect(step(top: 500, jumps: 2) == .settled)
        #expect(step(top: 500, jumps: 2, hasPendingJump: true) == .waitForJump)
    }
}

@Suite("Transcript paging coordinates")
struct TranscriptPagingTests {
    private func frame(top: CGFloat, height: CGFloat, measuredY: CGFloat) -> TranscriptMessageFrame {
        .init(sequence: 61, rect: CGRect(x: 68, y: measuredY, width: 400, height: height),
              historyStart: 31, contentTop: top)
    }

    @Test func replayingAFrameCannotAddItsCorrectionAgain() {
        let measured = frame(top: 1455, height: 37, measuredY: 1392)
        var offset: CGFloat = 83
        for _ in 0..<4 {
            offset = TranscriptCoordinates.targetOffset(for: measured, bottom: 79, topInset: 0)
            #expect(offset == 1433)
        }
    }

    @Test func scrollingReprojectsACachedFrameInsteadOfWaitingForAnotherPreference() {
        let cached = frame(top: 2055, height: 57, measuredY: 2023)
        let positioned = TranscriptCoordinates.viewportFrame(cached, top: 2002)
        #expect(positioned.rect == CGRect(x: 68, y: 73, width: 400, height: 57))
        #expect(positioned.rect.maxY == 130)
        #expect(positioned.contentTop == cached.contentTop)
        #expect(positioned.historyStart == cached.historyStart)
        #expect(positioned.sequence == cached.sequence)
        #expect(TranscriptCoordinates.viewportFrame(positioned, top: 2032).rect.maxY == 100)
    }

    @Test func continuedScrollingMovesThePlaceToKeepBeforeTheOlderPageArrives() {
        let cached = frame(top: 84, height: 58, measuredY: 81)
        let first = TranscriptCoordinates.viewportFrame(cached, top: 23)
        let later = TranscriptCoordinates.viewportFrame(cached, top: 83)
        #expect(first.rect.maxY == 139)
        #expect(later.rect.maxY == 79)
        let loaded = frame(top: 1455, height: 37, measuredY: 1392)
        #expect(TranscriptCoordinates.targetOffset(for: loaded, bottom: later.rect.maxY,
                                                   topInset: 0) == 1433)
    }

    @Test func theToolbarInsetIsRemovedOnlyFromTheNativeOffset() {
        let measured = frame(top: 2055, height: 57, measuredY: 2023)
        #expect(TranscriptCoordinates.targetOffset(for: measured, bottom: 130, topInset: 52) == 1950)
        #expect(TranscriptCoordinates.targetOffset(for: measured, bottom: 130, topInset: 76) == 1926)
    }

    @Test func joiningARunKeepsTheMessagesBottomWhenItsRepeatedHeaderDisappears() {
        let before = frame(top: 84, height: 58, measuredY: 21)
        let joined = frame(top: 1465, height: 37, measuredY: 1381)
        let oldOffset = TranscriptCoordinates.targetOffset(for: before, bottom: 79, topInset: 0)
        let newOffset = TranscriptCoordinates.targetOffset(for: joined, bottom: 79, topInset: 0)
        #expect(oldOffset == 83)
        #expect(newOffset == 1443)
        #expect(newOffset - oldOffset == 1360)
    }

    @Test func scrollingDoesNotChangeTheTargetButALazyHeightCorrectionDoes() {
        for y: CGFloat in [-963, 21, 1381] {
            let measured = frame(top: 1465, height: 37, measuredY: y)
            #expect(TranscriptCoordinates.targetOffset(for: measured, bottom: 79,
                                                       topInset: 0) == 1443)
        }
        let corrected = frame(top: 1455, height: 37, measuredY: 21)
        #expect(TranscriptCoordinates.targetOffset(for: corrected, bottom: 79,
                                                   topInset: 0) == 1433)
    }

    @Test func restorationWaitsUntilBothNativeScrollingAndItsMeasuredFrameAgree() {
        let stale = frame(top: 1455, height: 37, measuredY: 1392)
        let measured = frame(top: 1455, height: 37, measuredY: 42)
        func restored(_ frame: TranscriptMessageFrame, bottom: CGFloat = 79, nativeIsAligned: Bool = true) -> Bool {
            TranscriptCoordinates.isRestored(frame, bottom: bottom, nativeIsAligned: nativeIsAligned)
        }
        #expect(!restored(stale))
        #expect(!restored(measured, nativeIsAligned: false))
        #expect(restored(measured))
        #expect(restored(measured, bottom: 79.5))
        #expect(!restored(measured, bottom: 79.51))
    }

    @Test func readMarkingUsesNativeContentBoundsWithoutReprojectingEveryFrame() {
        let viewport = TranscriptViewport(width: 600, height: 400)
        let measured = [
            "visible": frame(top: 1000, height: 60, measuredY: 2000),
            "below": TranscriptMessageFrame(sequence: 99, rect: CGRect(x: 68, y: 80, width: 400, height: 60),
                                           historyStart: 31, contentTop: 1450),
            "optimistic": TranscriptMessageFrame(sequence: 0, rect: CGRect(x: 68, y: 80, width: 400, height: 60),
                                                historyStart: 31, contentTop: 1000)
        ]
        #expect(viewport.readSequence(in: measured) == 99)
        #expect(viewport.readSequence(in: measured, nativeViewportTop: 1020) == 61)
        #expect(viewport.readSequence(in: measured, nativeViewportTop: 1470) == 99)
        #expect(viewport.readSequence(in: measured, nativeViewportTop: 2000) == nil)
        #expect(TranscriptViewport().readSequence(in: measured, nativeViewportTop: 1020) == nil)
    }

    @Test(arguments: [CGFloat(0), 52, 2002, 2032])
    func nativeReadBoundsKeepTheSameVisibilityThresholdsAsPositionedFrames(_ top: CGFloat) {
        let viewport = TranscriptViewport(width: 600, height: 400)
        for (relativeTop, height, x) in [
            (CGFloat(-100), CGFloat(60), CGFloat(68)),
            (-36, 60, 68), (-36.01, 60, 68), (80, 60, 68),
            (376, 100, 68), (376.01, 100, 68), (390, 20, 68), (391, 20, 68),
            (20, 40, 700)
        ] {
            var measured = frame(top: top - TranscriptCoordinates.contentTopPadding + relativeTop,
                                 height: height, measuredY: 9999)
            measured.rect.origin.x = x
            let positioned = TranscriptCoordinates.viewportFrame(measured, top: top)
            #expect(viewport.readSequence(in: ["message": measured], nativeViewportTop: top)
                    == viewport.readSequence(in: ["message": positioned]))
        }
    }
}

@MainActor
@Suite("Image viewer")
struct ImageViewerTests {
    /// A 1000 x 800 canvas under a 52-point toolbar.
    private static let layout = ImageViewer.Layout(size: CGSize(width: 1000, height: 800), topInset: 52)
    private static let screenshot = CGSize(width: 800, height: 600)
    private static let photo = CGSize(width: 2400, height: 1800)

    @Test func subtitlesReadTheDayTimeAndPosition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let dates = ISO8601DateFormatter()
        let now = try #require(dates.date(from: "2026-10-22T20:00:00Z"))
        func subtitle(_ sent: String?, _ index: Int, _ count: Int) -> String {
            ImageViewer.subtitle(sentAt: sent.flatMap(dates.date(from:)), index: index, count: count,
                                 now: now, calendar: calendar)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(subtitle("2026-10-22T17:23:00Z", 1, 4) == "Today at 5:23 PM · 2 of 4")
        #expect(subtitle("2026-10-21T09:05:00Z", 0, 1) == "Yesterday at 9:05 AM")
        #expect(subtitle(nil, 2, 3) == "3 of 3")
    }

    @Test func imagesFitBelowTheToolbarAndNeverUpscale() throws {
        let viewer = try openViewer([Self.screenshot, Self.photo])
        defer { viewer.close(animated: false) }
        let layout = Self.layout
        // 16 points below the toolbar, and 80 above the bottom for the capsule.
        #expect(viewer.availableRect(in: layout) == CGRect(x: 24, y: 68, width: 952, height: 652))
        // A 2x screenshot shows at its point size, centered in that area.
        #expect(viewer.fitScale(at: 0, in: layout) == 1)
        #expect(viewer.frame(at: 0, in: layout) == CGRect(x: 300, y: 244, width: 400, height: 300))
        let photo = viewer.frame(at: 1, in: layout)
        #expect(abs(viewer.fitScale(at: 1, in: layout) - 652.0 / 900) < 0.0001)
        #expect(abs(photo.minY - 68) < 0.001 && abs(photo.maxY - 720) < 0.001)
        // Without the measured toolbar the image would center against the whole canvas.
        #expect(viewer.frame(at: 0, in: .init(size: layout.size, topInset: 0)).midY == 368)
        let single = try openViewer([Self.photo])
        defer { single.close(animated: false) }
        #expect(single.availableRect(in: Self.layout).height == 708)
        #expect(ImageViewer.knownPixelSize(of: try #require(single.session?.images.first),
                                           api: try #require(single.session?.api)) == Self.photo)
    }

    @Test func zoomStepsThroughTheLadderAndReturnsToFit() throws {
        let viewer = try openViewer([Self.photo])
        defer { viewer.close(animated: false) }
        #expect(!viewer.isZoomed && !viewer.canZoomOut && viewer.canZoomIn)
        viewer.zoomIn()
        #expect(viewer.zoom == 1 && viewer.isActualSize)
        viewer.zoomIn()
        #expect(viewer.zoom == 1.5)
        viewer.zoomOut()
        #expect(viewer.zoom == 1)
        // The next step down, 0.75, is below the fitted scale, so the image fits again.
        viewer.zoomOut()
        #expect(viewer.zoom == nil && viewer.pan == .zero)
        viewer.actualSize()
        #expect(viewer.zoom == 1)
        for _ in 0..<12 { viewer.zoomIn() }
        #expect(viewer.zoom == ImageViewer.maximumZoom && !viewer.canZoomIn)
        let fitted = try openViewer([Self.screenshot])
        defer { fitted.close(animated: false) }
        fitted.actualSize()
        #expect(fitted.zoom == nil && fitted.isActualSize)
        let area = fitted.availableRect(in: Self.layout)
        fitted.toggleZoom(at: CGPoint(x: area.midX, y: area.midY))
        #expect(fitted.zoom == 2)
    }

    @Test func aZoomedImagePansOnlyUntilItsEdgesMeetTheArea() throws {
        let viewer = try openViewer([Self.photo])
        defer { viewer.close(animated: false) }
        viewer.pan(by: CGSize(width: 50, height: 50))
        #expect(viewer.pan == .zero)
        viewer.actualSize()
        viewer.pan(by: CGSize(width: 10_000, height: -10_000))
        // At 1200 x 900 points in a 952 x 708 area, the edges meet 124 and 96 points out.
        #expect(viewer.pan == CGSize(width: 124, height: -96))
    }

    @Test func zoomingKeepsThePointUnderThePointerInPlace() throws {
        let viewer = try openViewer([Self.photo])
        defer { viewer.close(animated: false) }
        let area = viewer.availableRect(in: Self.layout)
        let point = CGPoint(x: area.midX + 60, y: area.midY - 40)
        let before = viewer.frame(at: 0, in: Self.layout)
        let relative = CGPoint(x: (point.x - before.minX) / before.width, y: (point.y - before.minY) / before.height)
        viewer.toggleZoom(at: point)
        #expect(viewer.zoom == 1)
        let after = viewer.frame(at: 0, in: Self.layout)
        #expect(abs(after.minX + relative.x * after.width - point.x) < 0.001)
        #expect(abs(after.minY + relative.y * after.height - point.y) < 0.001)
        // A pinch never shrinks the image below its fitted size.
        let base = try #require(viewer.magnificationBase)
        viewer.magnify(by: 0.2, from: base, at: point)
        #expect(viewer.zoom == nil && viewer.pan == .zero)
    }

    @Test func closingWithoutACanvasEndsTheSessionAndReturnsFocusToTheTile() throws {
        let viewer = try openViewer([Self.screenshot, Self.screenshot], at: 1)
        #expect(viewer.presentation?.index == 1)
        viewer.close()
        #expect(viewer.session == nil && viewer.presentation == nil)
        #expect(viewer.focusReturn?.messageID == "m1" && viewer.focusReturn?.index == 1)
    }

    @Test func aStaleCloseLeavesANewerSessionOpen() throws {
        let viewer = try openViewer([Self.screenshot, Self.screenshot])
        defer { viewer.close(animated: false) }
        let first = try #require(viewer.session)
        viewer.open(images: first.images, at: 1, source: first.source, api: first.api)
        let second = try #require(viewer.session?.id)
        viewer.finishClosing(first.id)
        #expect(viewer.session?.id == second && viewer.index == 1)
    }

    @Test func theImageStandsInForItsTileOnlyWhileItZoomsOutOfOrIntoIt() throws {
        // The canvas starts 300 points into the window, under a 52-point toolbar. The second tile
        // has scrolled mostly under the toolbar.
        let frames = ImageViewerThumbnailFrames()
        frames.frames = [0: CGRect(x: 400, y: 300, width: 120, height: 90),
                         1: CGRect(x: 530, y: 0, width: 120, height: 90)]
        let layout = ImageViewer.Layout(size: Self.layout.size, topInset: 52, origin: CGPoint(x: 300, y: 0))
        let viewer = try openViewer([Self.screenshot, Self.screenshot], thumbnails: frames)
        viewer.layout = layout
        #expect(viewer.standsInForTile)
        viewer.canvasAppeared()
        defer { viewer.canvasDisappeared() }
        viewer.close()
        #expect(viewer.isClosing && viewer.closingFrame == frames.frames[0] && viewer.standsInForTile)
        viewer.finishClosing(try #require(viewer.session?.id))
        #expect(viewer.session == nil && viewer.closingFrame == nil && !viewer.standsInForTile)

        // Less than half of the second tile shows, so the image fades in place and the tile stays.
        let images = try (0..<2).map { _ in
            ChannelAttachment(mimeType: "image/png", base64: try solidPNG(width: 800, height: 600))
        }
        let source = ImageViewer.Source(messageID: "m1", sender: "Lead", timestamp: "2026-10-22T17:23:00Z")
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        viewer.open(images: images, at: 1, source: source, api: api, thumbnails: frames)
        viewer.layout = layout
        #expect(viewer.standsInForTile)
        viewer.close()
        #expect(viewer.isClosing && viewer.closingFrame == nil && !viewer.standsInForTile)
        viewer.finishClosing(try #require(viewer.session?.id))

        // Without a tile frame the image crossfades both ways.
        viewer.open(images: images, at: 0, source: source, api: api)
        #expect(!viewer.standsInForTile)
        viewer.close(animated: false)
    }

    @Test func unnamedImagesAreNamedByPositionAndDataURLsNeverNameAFile() throws {
        let inline = ChannelAttachment(url: "data:image/png;base64,iVBORw0KGgo=", mimeType: "image/png")
        #expect(transcriptAttachmentFilename(inline) == nil)
        #expect(transcriptImageName(inline, index: 1, count: 3) == "Image 2 of 3")
        #expect(transcriptImageName(inline, index: 0, count: 1) == "Image")
        let remote = ChannelAttachment(url: "http://localhost:3210/files/plan.png", mimeType: "image/png")
        #expect(transcriptImageName(remote, index: 0, count: 2) == "plan.png")
        let viewer = try openViewer([Self.screenshot, Self.screenshot], at: 1, names: ["plan.png", nil])
        defer { viewer.close(animated: false) }
        #expect(viewer.presentation?.filename == "Image 2 of 2")
        #expect(viewer.accessibilityLabel == "Image 2 of 2 from Lead")
        viewer.show(0)
        #expect(viewer.accessibilityLabel == "Image 1 of 2 from Lead, plan.png")
    }

    @Test func exportsLinkTheCachedFileUnderASafeFilename() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("viewer-export-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(UUID().uuidString).png")
        try Data("pixels".utf8).write(to: file)
        let exported = try #require(ImageViewer.export(file, named: "Q3/plan: final"))
        defer {
            try? manager.removeItem(at: exported.deletingLastPathComponent())
            try? manager.removeItem(at: directory)
        }
        #expect(exported.lastPathComponent == "Q3-plan- final.png")
        #expect(try Data(contentsOf: exported) == Data("pixels".utf8))
        #expect(ImageViewer.export(file, named: "Q3/plan: final") == exported)
        #expect(ImageViewer.export(file, named: "photo.jpeg")?.lastPathComponent == "photo.jpeg")
    }

    /// Opens inline PNGs whose sizes come from their headers, so the fit is known before decoding.
    private func openViewer(_ sizes: [CGSize], at index: Int = 0, names: [String?]? = nil,
                            thumbnails: ImageViewerThumbnailFrames? = nil) throws -> ImageViewer {
        let images = try sizes.enumerated().map { position, size in
            ChannelAttachment(name: names?[position], mimeType: "image/png",
                              base64: try solidPNG(width: Int(size.width), height: Int(size.height)))
        }
        let viewer = ImageViewer()
        viewer.reducesMotion = true
        viewer.open(images: images, at: index,
                    source: .init(messageID: "m1", sender: "Lead", timestamp: "2026-10-22T17:23:00Z"),
                    api: try ChannelAPI(serverURL: "http://localhost:3210"), thumbnails: thumbnails)
        viewer.layout = Self.layout
        return viewer
    }

    private func solidPNG(width: Int, height: Int) throws -> String {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data).base64EncodedString()
    }
}

@MainActor
@Suite("Image viewer Live Text", .serialized, .enabled(if: ImageAnalyzer.isSupported))
struct ImageViewerLiveTextTests {
    @Test(.readsTextInImages) func onlyTheSettledCurrentImageIsAnalyzedAndTheWindowRemembersIt() async throws {
        let viewer = try Self.openViewer([Self.textPNG("Release notes ship Friday"),
                                          Self.textPNG("Quarterly roadmap review"), Self.textPNG(nil)])
        defer { viewer.close(animated: false) }
        // The current image and its neighbor load.
        try await Self.until { viewer.items[0]?.bitmap != nil && viewer.items[1]?.bitmap != nil }
        // Nothing is analyzed during the opening motion.
        #expect(viewer.items[0]?.analysis == nil && viewer.liveText == nil)
        viewer.openingDidSettle()
        try await Self.until { viewer.liveText != nil }
        #expect(viewer.liveText?.transcript.contains("Release") == true)
        // An image paged past before it settles is never analyzed.
        viewer.show(1)
        viewer.show(0)
        // An image without text has an analysis but no Live Text.
        viewer.show(2)
        try await Self.until { viewer.items[2]?.analysis != nil }
        #expect(viewer.items[1]?.analysis == nil)
        #expect(viewer.liveText == nil)
        viewer.show(1)
        try await Self.until { viewer.liveText != nil }
        #expect(viewer.liveText?.transcript.contains("roadmap") == true)
        #expect(viewer.rememberedAnalysisCount == 3)
        // Reopening uses the window's analyses without waiting.
        let images = try #require(viewer.session?.images)
        viewer.close(animated: false)
        viewer.open(images: images, at: 1, source: Self.source, api: try Self.api())
        try await Self.until { viewer.items[1]?.bitmap != nil }
        viewer.openingDidSettle()
        #expect(viewer.liveText?.transcript.contains("roadmap") == true)
        #expect(viewer.items[0]?.analysis == nil)
    }

    @Test(.readsTextInImages,
          .enabled(if: ProcessInfo.processInfo.environment["TOY_BOX_TEST_LIVE_TEXT_INTERACTION"] == "1"))
    func pressesOnTextReachLiveTextAndEverythingElseReachesTheViewer() async throws {
        let viewer = try Self.openViewer([Self.textPNG("Release notes ship Friday")])
        let window = Self.host(viewer)
        defer {
            viewer.close(animated: false)
            window.close()
        }
        try await Self.until { viewer.liveText != nil }
        let content = try #require(window.contentView)
        let view = try #require(Self.find(ImageViewerLiveTextView.self, in: content))
        func point(_ x: CGFloat, _ y: CGFloat) throws -> CGPoint {
            let image = viewer.frame(at: 0, in: try #require(viewer.layout))
            let point = CGPoint(x: image.minX + image.width * x, y: image.minY + image.height * y)
            return view.convert(point, to: nil)
        }
        func isOverLiveText(_ point: CGPoint) -> Bool { view.isOverLiveText(view.convert(point, from: nil)) }
        // The text runs along the top of the image, so this also proves the overlay isn't flipped.
        let word = try point(0.15, 0.26)
        let blank = try point(0.15, 0.74)
        try await Self.until { isOverLiveText(word) && !view.overlay.isSupplementaryInterfaceHidden }
        try await transcriptSettled(in: content) { view.overlay.layer?.presentation()?.frame ?? view.overlay.frame }
        // VisionKit establishes its native text tracking when the pointer enters the image.
        Self.send([(.mouseMoved, word, 0)], to: window)
        try await transcriptFrame(in: content)
        #expect(isOverLiveText(word))
        #expect(!isOverLiveText(blank))
        #expect(!view.overlay.isSupplementaryInterfaceHidden)

        // Double-clicking a word selects it rather than zooming.
        Self.click(window, at: word, count: 2)
        try await Self.until { viewer.selectedLiveText != nil }
        #expect(viewer.selectedLiveText == "Release")
        #expect(!viewer.isZoomed)
        // The viewer takes the keyboard back and the selection stays, so Copy copies the text.
        try await Self.until { !((window.firstResponder as? NSView)?.isDescendant(of: view.overlay) ?? false) }
        #expect(!viewer.isPressingLiveText)
        #expect(viewer.selectedLiveText == "Release")
        #expect(viewer.copiedItems.first?.canLoadObject(ofClass: NSString.self) == true)
        // Escape lets go of the selection first, then closes.
        viewer.escape()
        #expect(viewer.selectedLiveText == nil && viewer.session != nil && !viewer.isClosing)
        #expect(viewer.copiedItems.first?.canLoadObject(ofClass: NSImage.self) == true)

        // Dragging across words selects them.
        Self.drag(window, from: word, to: try point(0.36, 0.26), clicks: 2)
        try await Self.until { viewer.selectedLiveText?.contains("notes") == true }
        #expect(viewer.selectedLiveText?.contains("Release") == true)
        #expect(!viewer.isZoomed && viewer.session != nil)
        viewer.escape()

        // Double-clicking elsewhere zooms, which hides the button but keeps the text selectable.
        Self.click(window, at: blank, count: 2)
        try await Self.until { viewer.isZoomed }
        let zoomedWord = try point(0.15, 0.26)
        try await Self.until { view.overlay.isSupplementaryInterfaceHidden && isOverLiveText(zoomedWord) }
        try await transcriptSettled(in: content) { view.overlay.layer?.presentation()?.frame ?? view.overlay.frame }
        #expect(view.overlay.isSupplementaryInterfaceHidden)
        #expect(isOverLiveText(zoomedWord))
        Self.click(window, at: zoomedWord, count: 2)
        try await Self.until { viewer.selectedLiveText != nil }
        #expect(viewer.isZoomed)
        // A click away from the text lets go of the selection.
        Self.click(window, at: try point(0.15, 0.74), count: 1)
        try await Self.until { viewer.selectedLiveText == nil }

        // While zoomed, a drag on text selects instead of panning.
        let pan = viewer.pan
        let start = try point(0.1, 0.26)
        #expect(isOverLiveText(start))
        Self.drag(window, from: start, to: CGPoint(x: start.x + 120, y: start.y), clicks: 2)
        try await Self.until { viewer.selectedLiveText != nil }
        #expect(viewer.pan == pan && viewer.isZoomed)
        viewer.escape()
        #expect(viewer.selectedLiveText == nil && !viewer.isClosing)
        viewer.escape()
        #expect(viewer.isClosing)
    }

    @Test(.readsTextInImages, .enabled(if: transcriptTimingTestsEnabled))
    func theSelectionHighlightCoversItsTextAndTheButtonStaysInTheImagesCorner() async throws {
        let page = try #require(Self.screenshotImage())
        let analysis = try await ImageAnalyzer().analyze(page.image, orientation: .up,
                                                         configuration: ImageAnalyzer.Configuration([.text]))
        let view = ImageViewerLiveTextView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        view.wantsLayer = true
        // The window stays deferred and never reaches WindowServer. An event from WindowServer that arrives
        // while a test awaits stops the test runner's run loop and ends the process, and VisionKit draws and
        // hit-tests without one.
        let window = KeyWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.stop()
            window.close()
        }
        let line = 4

        // Fitted below a 52-point toolbar, the image sits 22 points below the canvas's center, and
        // zoomed and panned it can sit anywhere.
        let fitted = CGRect(x: 200, y: 218, width: 600, height: 408)
        let zoomed = CGRect(x: -20, y: -150, width: 1200, height: 816)
        for frame in [fitted, zoomed] {
            view.present(analysis: analysis, in: frame, animated: false)
            view.layoutSubtreeIfNeeded()
            view.overlay.resetSelection()
            try await Self.until { view.overlay.text.contains(page.lines[line]) }
            try await transcriptSettled(in: view) { Self.layerPixels(of: view) }
            let unselected = Self.layerPixels(of: view)
            view.overlay.selectedRanges = [try #require(view.overlay.text.range(of: page.lines[line]))]
            #expect(view.overlay.selectedText == page.lines[line])
            var highlight: CGRect?
            try await Self.until {
                highlight = Self.changedBounds(unselected, Self.layerPixels(of: view), width: 1000)
                return highlight != nil
            }
            let drawn = try #require(highlight)
            let text = page.bounds(of: line, in: frame)
            let tolerance = max(3, text.height / 4)
            #expect(abs(drawn.midY - text.midY) <= tolerance, "highlight \(drawn) over text \(text) in \(frame)")
            #expect(abs(drawn.minX - text.minX) <= tolerance, "highlight \(drawn) over text \(text) in \(frame)")
            #expect(abs(drawn.maxX - text.maxX) <= tolerance, "highlight \(drawn) over text \(text) in \(frame)")
        }

        // VisionKit's button sits 8 points inside the fitted image's bottom-trailing corner.
        view.overlay.resetSelection()
        view.present(analysis: analysis, in: fitted, animated: false)
        view.layoutSubtreeIfNeeded()
        let button = CGPoint(x: fitted.maxX - 21, y: fitted.maxY - 21)
        try await Self.until { view.target(at: button).control }
        for point in [CGPoint(x: fitted.maxX - 21, y: fitted.maxY - 45), CGPoint(x: fitted.maxX - 45, y: fitted.maxY - 21),
                      CGPoint(x: fitted.maxX + 4, y: fitted.maxY - 21), CGPoint(x: fitted.maxX - 21, y: fitted.maxY + 4)] {
            #expect(!view.target(at: point).control, "button at \(point)")
        }
    }

    @Test func onlyPointerEventsOnWhatVisionKitDrawsAreRoutedToIt() {
        typealias Target = ImageViewerLiveTextView.Target
        let text = Target(text: true)
        let selected = Target(text: true, hasSelection: true)
        let control = Target(control: true)
        for type: NSEvent.EventType in [.leftMouseDown, .mouseMoved, .cursorUpdate] {
            #expect(ImageViewerLiveTextView.routes(type, to: text))
            #expect(ImageViewerLiveTextView.routes(type, to: control))
            #expect(!ImageViewerLiveTextView.routes(type, to: Target(hasSelection: true)))
        }
        // The text menu only opens on a selection. Everywhere else a right-click is unchanged.
        #expect(!ImageViewerLiveTextView.routes(.rightMouseDown, to: text))
        #expect(ImageViewerLiveTextView.routes(.rightMouseDown, to: selected))
        #expect(!ImageViewerLiveTextView.routes(.rightMouseDown, to: Target(control: true, hasSelection: true)))
        // Scrolling, pinching and swiping always reach the viewer.
        for type: NSEvent.EventType in [.scrollWheel, .magnify, .smartMagnify, .swipe, .gesture, .keyDown] {
            #expect(!ImageViewerLiveTextView.routes(type, to: selected))
        }
        #expect(!ImageViewerLiveTextView.routes(nil, to: selected))
    }

    @Test func theButtonMatchesTheImageCornerBeneathIt() throws {
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        /// A 600 x 400 image in `fill`, with its bottom-trailing or top-trailing 128-pixel square in `corner`.
        func image(_ fill: CGColor, corner: CGColor? = nil, top: Bool = false) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(fill)
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            if let corner {
                context.setFillColor(corner)
                // Core Graphics draws from the bottom-left.
                context.fill(CGRect(x: 472, y: top ? 272 : 0, width: 128, height: 128))
            }
            return try #require(context.makeImage())
        }
        func tone(_ image: CGImage) throws -> ImageViewerCornerTone {
            try #require(ImageViewerCornerTone(image, pixelsPerPoint: 2))
        }
        // Only the 64-point square under the button counts, at the display's scale.
        #expect(try tone(image(white)).isLight(over: 0))
        #expect(try !tone(image(white, corner: black)).isLight(over: 1))
        #expect(try tone(image(black, corner: white)).isLight(over: 0))
        #expect(try !tone(image(black, corner: white, top: true)).isLight(over: 1))
        #expect(try tone(image(white)).luminance > 0.99)
        // Where the image is transparent, the canvas behind it decides.
        let clear = try tone(image(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)))
        #expect(clear.coverage == 0)
        #expect(clear.isLight(over: 1) && !clear.isLight(over: 0))
        // Mid gray sits below the threshold, since relative luminance is linear.
        #expect(try !tone(image(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))).isLight(over: 1))

        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))
        let paper = ImageViewerCornerTone(luminance: 1, coverage: 1)
        let night = ImageViewerCornerTone(luminance: 0.02, coverage: 1)
        let cutout = ImageViewerCornerTone(luminance: 1, coverage: 0)
        #expect(ImageViewerLiveTextView.overlayAppearance(for: paper, in: dark) == .aqua)
        #expect(ImageViewerLiveTextView.overlayAppearance(for: night, in: light) == .darkAqua)
        #expect(ImageViewerLiveTextView.overlayAppearance(for: cutout, in: dark) == .darkAqua)
        #expect(ImageViewerLiveTextView.overlayAppearance(for: cutout, in: light) == .aqua)
        #expect(ImageViewerLiveTextView.overlayAppearance(for: nil, in: dark) == nil)
    }

    @Test func aWhiteScreenshotInADarkWindowGetsALightButtonAndAWindowMenu() async throws {
        // The viewer measures each image once, as it decodes.
        let viewer = try Self.openViewer([Self.textPNG("Release notes ship Friday")])
        defer { viewer.close(animated: false) }
        try await Self.until { viewer.items[0]?.cornerTone != nil }
        let tone = try #require(viewer.items[0]?.cornerTone)
        #expect(tone.isLight(over: 0))

        let view = ImageViewerLiveTextView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.cornerTone = tone
        #expect(view.overlay.appearance?.name == .aqua)
        #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        // The text menu belongs to the window, not the image.
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        let menu = view.overlayView(view.overlay, updatedMenuFor: NSMenu(), for: event, at: .zero)
        #expect(menu.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        // The window changing doesn't change what's under the button, unless the canvas shows through.
        view.appearance = NSAppearance(named: .aqua)
        #expect(view.overlay.appearance?.name == .aqua)
        view.cornerTone = ImageViewerCornerTone(luminance: 1, coverage: 0)
        #expect(view.overlay.appearance?.name == .aqua)
        view.appearance = NSAppearance(named: .darkAqua)
        #expect(view.overlay.appearance?.name == .darkAqua)
        // Until an image is measured, the overlay follows the window.
        view.cornerTone = nil
        #expect(view.overlay.appearance == nil)
    }

    @Test func theTextMenuDropsVisionKitsImageItems() {
        let menu = NSMenu()
        func item(_ title: String, _ tag: Int) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            menu.addItem(item)
        }
        item("Copy Image", ImageAnalysisOverlayView.MenuTag.copyImage)
        menu.addItem(.separator())
        item("Copy", 0)
        item("Look Up", 0)
        item("Translate", 0)
        menu.addItem(.separator())
        item("Share Image", ImageAnalysisOverlayView.MenuTag.shareImage)
        item("Look Up Item", ImageAnalysisOverlayView.MenuTag.lookupItem)
        ImageViewerLiveTextView.removeImageItems(from: menu)
        #expect(menu.items.map(\.title) == ["Copy", "Look Up", "Translate"])
    }

    // MARK: Helpers

    private static let source = ImageViewer.Source(messageID: "m1", sender: "Lead", timestamp: "2026-10-22T17:23:00Z")

    private static func api() throws -> ChannelAPI { try ChannelAPI(serverURL: "http://localhost:3210") }

    private static func openViewer(_ images: [String]) throws -> ImageViewer {
        let viewer = ImageViewer()
        viewer.reducesMotion = true
        viewer.open(images: images.map { ChannelAttachment(mimeType: "image/png", base64: $0) }, at: 0,
                    source: source, api: try api())
        viewer.layout = ImageViewer.Layout(size: CGSize(width: 1000, height: 800), topInset: 52)
        return viewer
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// Opt-in WindowServer interaction, separate from the default in-process rendering checks.
    private static func host(_ viewer: ImageViewer) -> NSWindow {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: ImageViewerCanvas().environment(viewer)
            .frame(width: 1000, height: 800))
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        window.makeKey()
        return window
    }

    private static func click(_ window: NSWindow, at point: CGPoint, count: Int) {
        send((1...count).flatMap { clicks in
            [(NSEvent.EventType.leftMouseDown, point, clicks), (.leftMouseUp, point, clicks)]
        }, to: window)
    }

    /// The test app can't become active, so AppKit holds back a lone press as the click that would bring
    /// the window forward, and only lets it through once another press follows. A double-click drag gets
    /// both through, and is also how Mac text is dragged a word at a time.
    private static func drag(_ window: NSWindow, from start: CGPoint, to end: CGPoint, clicks: Int = 1) {
        let moves = (1...8).map { step in
            let progress = CGFloat(step) / 8
            let point = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
            return (NSEvent.EventType.leftMouseDragged, point, clicks)
        }
        let presses = (1..<clicks).flatMap { count in
            [(NSEvent.EventType.leftMouseDown, start, count), (.leftMouseUp, start, count)]
        }
        send(presses + [(.leftMouseDown, start, clicks)] + moves + [(.leftMouseUp, end, clicks)], to: window)
    }

    /// Posts mouse events stamped a frame apart to the app's queue and dispatches them, so hit-testing sees
    /// the current event and local monitors and gesture recognizers run, as they do for a real press.
    private static func send(_ events: [(type: NSEvent.EventType, point: CGPoint, clicks: Int)], to window: NSWindow) {
        let start = ProcessInfo.processInfo.systemUptime
        let events = events.enumerated().compactMap { index, event in
            NSEvent.mouseEvent(with: event.type, location: event.point, modifierFlags: [],
                               timestamp: start + Double(index) / 60, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: event.clicks,
                               pressure: event.type == .leftMouseUp ? 0 : 1)
        }
        // Posting an event stops whichever run of the main run loop is current, to wake anything waiting
        // for events, and AppKit posts more while it handles a click. Under Swift's async main the current
        // run is the test runner's own, and stopping it ends the process, so all of this happens in a nested run.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            let app = NSApplication.shared
            for event in events { app.postEvent(event, atStart: false) }
            while let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.1), inMode: .default,
                                            dequeue: true) {
                app.sendEvent(event)
            }
        }
        CFRunLoopRunInMode(.defaultMode, 0, true)
    }

    private static func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    private struct Timeout: Error {}

    /// Loads and analyses share the machine with every other suite in a full run, so waits are generous.
    private static func until(_ timeout: Duration = .seconds(30), sourceLocation: SourceLocation = #_sourceLocation,
                              _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out", sourceLocation: sourceLocation)
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static var visionKitReadsText: Bool?

    /// Whether VisionKit itself finds the text in a plain text image, decided once per run.
    static func probeVisionKitReadsText() async -> Bool {
        if let visionKitReadsText { return visionKitReadsText }
        let probe = LiveTextProbe()
        probe.start(textImage("Release notes ship Friday"))
        let deadline = ContinuousClock.now + .seconds(20)
        while probe.result == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let reads = probe.result ?? false
        visionKitReadsText = reads
        return reads
    }

    /// A 1200 x 600 white image with one line of black text along its top, or blank.
    private static func textPNG(_ text: String?) throws -> String {
        let image = try #require(textImage(text))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data).base64EncodedString()
    }

    private static func textImage(_ text: String?) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        if let text {
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
            let string = NSAttributedString(string: text, attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            context.textPosition = CGPoint(x: 60, y: 420)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        return context.makeImage()
    }

    private struct ScreenshotPage {
        var image: CGImage
        var lines: [String]
        /// Each line's glyph bounds in pixels from the image's top-left.
        var glyphBounds: [CGRect]

        /// A line's glyph bounds where the image is shown at `frame`.
        func bounds(of line: Int, in frame: CGRect) -> CGRect {
            let x = frame.width / CGFloat(image.width), y = frame.height / CGFloat(image.height)
            let glyphs = glyphBounds[line]
            return CGRect(x: frame.minX + glyphs.minX * x, y: frame.minY + glyphs.minY * y,
                          width: glyphs.width * x, height: glyphs.height * y)
        }
    }

    /// A 2x screenshot of 14-point text on 20-point lines, 1200 x 816 pixels.
    private static func screenshotImage() -> ScreenshotPage? {
        let lines = ["Launch week checklist", "Release notes ship Friday", "Quarterly roadmap review",
                     "Design sync moves to Tuesday", "Reconnect fix lands tonight", "Beta testers get builds first",
                     "Menu bar extra slips a release", "Sidebar polish wraps Thursday"]
        let width = 1200, height = 816
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        var glyphBounds: [CGRect] = []
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
            let baseline = CGFloat(60 + index * 40)
            context.textPosition = CGPoint(x: 60, y: CGFloat(height) - baseline)
            CTLineDraw(line, context)
            // Glyph bounds run up from the baseline.
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            glyphBounds.append(CGRect(x: 60 + glyphs.minX, y: baseline - glyphs.maxY,
                                      width: glyphs.width, height: glyphs.height))
        }
        guard let image = context.makeImage() else { return nil }
        return ScreenshotPage(image: image, lines: lines, glyphBounds: glyphBounds)
    }

    /// The view's layer tree rendered at one pixel per point, in rows from its top.
    private static func layerPixels(of view: NSView) -> [UInt32] {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let layer = view.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            if view.isFlipped {
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
        }
        return pixels
    }

    /// The bounds of every pixel that differs between two renders, in points from the top-left.
    private static func changedBounds(_ before: [UInt32], _ after: [UInt32], width: Int) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for pixel in 0..<min(before.count, after.count) where before[pixel] != after[pixel] {
            let x = pixel % width, y = pixel / width
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Analyzes one image on the main actor and records whether VisionKit found text in it.
@MainActor
private final class LiveTextProbe {
    var result: Bool?

    func start(_ image: CGImage?) {
        guard let image else { result = false; return }
        Task {
            let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up,
                                                              configuration: ImageAnalyzer.Configuration([.text]))
            result = analysis?.hasResults(for: .text) == true
        }
    }
}

extension Trait where Self == ConditionTrait {
    /// GitHub's macOS runners report Live Text as supported but never read text in an image, so CI
    /// asks VisionKit directly and skips. Locally it stays a requirement.
    static var readsTextInImages: Self {
        .disabled("This CI runner's VisionKit doesn't read text in images") {
            guard ProcessInfo.processInfo.environment["CI"] != nil else { return false }
            return await !ImageViewerLiveTextTests.probeVisionKitReadsText()
        }
    }
}

func stackTestAgents(_ colors: [String]) -> [ChannelAgent] {
    colors.enumerated().map { index, color in
        ChannelAgent(id: "agent-\(index)", name: "Agent \(index)", avatar: .init(mark: "M4 12H20", color: color))
    }
}

@MainActor
func renderedTranscriptBitmap(_ content: some View, size: CGSize,
                              appearance: NSAppearance? = nil) async throws -> NSBitmapImageRep {
    let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
    view.frame = NSRect(origin: .zero, size: size)
    view.appearance = appearance
    func pixels() throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
    try await transcriptSettled(in: view, reading: pixels)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

@MainActor
private final class TranscriptLayoutCapture {
    var frames: [String: TranscriptMessageFrame] = [:]
    var viewport = TranscriptViewport()
    var proxy: ScrollViewProxy?
    var hasLanded = false
    var isRestoringHistory = false
}

@MainActor
private final class TranscriptGapLog {
    var values: [CGFloat] = []
}

@MainActor
private func transcriptFrame(in view: NSView) async throws {
    view.layoutSubtreeIfNeeded()
    view.window?.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(16))
}

@MainActor
private func transcriptUntil(in view: NSView? = nil, timeout: Duration = .seconds(60),
                             sourceLocation: SourceLocation = #_sourceLocation,
                             failure: () -> String = { "The transcript did not reach the expected state" },
                             _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        if let view { try await transcriptFrame(in: view) }
        else { try await Task.sleep(for: .milliseconds(20)) }
    }
    try #require(condition(), Comment(rawValue: failure()), sourceLocation: sourceLocation)
}

/// Waits for three unchanged display frames instead of assuming layout finishes in a fixed interval.
@MainActor
private func transcriptSettled<Value: Equatable>(in view: NSView, reading: () throws -> Value) async throws {
    var previous = try reading()
    var unchanged = 0
    let deadline = ContinuousClock.now + .seconds(60)
    while unchanged < 3, ContinuousClock.now < deadline {
        try await transcriptFrame(in: view)
        let current = try reading()
        unchanged = current == previous ? unchanged + 1 : 0
        previous = current
    }
    try #require(unchanged == 3, "The transcript kept changing between display frames")
}

@MainActor
@Suite("Catch-up summary")
struct TranscriptCatchUpTests {
    /// Each test uses its own server, so the session's memo and dismissals never cross tests.
    let server = URL(string: "https://catch-up-\(UUID().uuidString.lowercased()).invalid")!
    let summary = CatchUp(needsYou: nil, changes: [.init(text: "Lead verified the reconnect fix.", sources: [12])],
                          through: 30)

    func make(_ state: ChannelState = catchUpTestState(), unreadAfter: Int? = 10, view: TranscriptView = .all,
              availability: IntelligenceAvailability = .available, isOn: Bool = true,
              timeout: Duration = .seconds(15)) -> TranscriptCatchUp? {
        TranscriptCatchUp.make(server: server, state: state, unreadAfter: unreadAfter, view: view,
                               availability: availability, isOn: isOn, timeout: timeout)
    }

    @Test func aLandingIsEligibleOnlyWithTheModelTheSettingAndEnoughToRead() throws {
        let catchUp = try #require(make())
        #expect(catchUp.phase == .loading)
        #expect(catchUp.generation != nil)
        #expect(catchUp.holdsLanding)
        #expect(catchUp.title == "Summarizing 20 new messages")
        #expect(make(availability: .unavailable(.modelNotReady)) == nil)
        #expect(make(isOn: false) == nil)
        #expect(make(view: .yours) == nil)
        #expect(make(unreadAfter: nil) == nil)
        #expect(make(unreadAfter: 28) == nil)
        let suite = "catch-up-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = TranscriptIntelligenceSettings.summarizesNewMessages
        #expect(TranscriptIntelligenceSettings.isOn(key, defaults: defaults))
        defaults.set(false, forKey: key)
        #expect(!TranscriptIntelligenceSettings.isOn(key, defaults: defaults))
    }

    @Test func dismissingHidesTheSummaryForThatBoundaryForTheRestOfTheSession() async throws {
        let catchUp = try #require(make())
        catchUp.dismiss()
        #expect(catchUp.generation == nil)
        #expect(make() == nil)
        #expect(make(unreadAfter: 9) != nil)
        try await transcriptUntil { catchUp.phase == .collapsed }
        #expect(catchUp.phase == .collapsed)
        #expect(!catchUp.holdsLanding)
    }

    @Test func aSummaryMadeEarlierIsThereOnTheFirstFrame() async throws {
        let service = StubChannelIntelligence(results: [.ready(summary)])
        let first = try #require(make())
        await first.run(using: service)
        #expect(first.phase == .ready(.init(catchUp: summary, count: 20)))
        #expect(first.title == "Summary of 20 new messages")

        let again = try #require(make())
        #expect(again.phase == first.phase)
        #expect(again.generation == nil)
        await again.run(using: service)
        #expect(service.catchUpCount == 1)
    }

    @Test func aSlowModelCollapsesAtTheTimeoutAndIsAskedAgainNextTime() async throws {
        let service = StubChannelIntelligence(results: [.ready(summary)], delay: .seconds(300))
        let catchUp = try #require(make(timeout: .milliseconds(50)))
        let start = ContinuousClock.now
        await catchUp.run(using: service)
        #expect(catchUp.phase == .collapsed)
        // Generous, since other suites can keep the main actor busy for seconds at a time.
        #expect(ContinuousClock.now - start < .seconds(60))
        #expect(make()?.phase == .loading)
    }

    @Test(arguments: [CatchUpResult.nothingNew, .declined, .unavailable(.modelNotReady)])
    func aSummaryWithNothingToSayCollapses(result: CatchUpResult) async throws {
        let catchUp = try #require(make())
        await catchUp.run(using: StubChannelIntelligence(results: [result]))
        #expect(catchUp.phase == .collapsed)
        #expect(catchUp.isFading)
        #expect(!catchUp.holdsLanding)
    }

    @Test func aLineFromAChannelEventLeadsWithThatEventsOwnSymbol() {
        var state = catchUpTestState()
        for (index, type) in [(11, "tasks_completed"), (12, "a_future_event")] {
            state.messages[index] = ChannelMessage(id: "m\(index + 1)", sequence: index + 1,
                                                   timestamp: "2026-10-22T12:00:00Z", sender: .system,
                                                   content: .system(.init(type: type)))
        }
        func slot(_ source: Int, isReplied: Bool? = nil) -> TranscriptCatchUpSlot {
            TranscriptCatchUpSlot(line: .init(text: "Line", sources: [source]), messages: state.messages,
                                  isReplied: isReplied)
        }
        #expect(slot(12) == .event("tasks_completed"))
        #expect(TranscriptSystemMessages.symbol(for: "tasks_completed") == "checkmark.circle.fill")
        for scheme in [ColorScheme.light, .dark] {
            #expect(TranscriptSystemMessages.symbolColor(for: "tasks_completed", in: scheme)
                    == ChannelTaskColors.changes(in: scheme).added)
        }
        #expect(slot(13) == .event("a_future_event"))
        #expect(TranscriptSystemMessages.symbol(for: "a_future_event") == "info.circle")
        #expect(slot(11) == .avatar("lead"))
        #expect(slot(12, isReplied: true) == .need(isReplied: true))
        #expect(slot(99) == .unknown)
    }

    @Test func aFailedUpdateKeepsTheSummaryAndUpdateTriesAgain() async throws {
        let newer = CatchUp(needsYou: nil, changes: [.init(text: "Ada shipped the beta.", sources: [34])], through: 36)
        let service = StubChannelIntelligence(results: [.ready(summary), .declined, .ready(newer)])
        let catchUp = try #require(make())
        await catchUp.run(using: service)
        let first = TranscriptCatchUp.Summary(catchUp: summary, count: 20)

        let later = catchUpTestState(through: 36)
        #expect(TranscriptCatchUp.newerCount(in: later.messages, after: summary.through) == 6)
        catchUp.update(from: later, server: server)
        #expect(catchUp.phase == .updating(first))
        #expect(catchUp.title == "Summarizing 26 new messages")
        await catchUp.run(using: service)
        #expect(catchUp.phase == .ready(first))
        #expect(catchUp.title == "Summary of 20 new messages")

        catchUp.update(from: later, server: server)
        #expect(catchUp.isGenerating)
        await catchUp.run(using: service)
        #expect(catchUp.phase == .ready(.init(catchUp: newer, count: 26)))
        #expect(service.catchUpCount == 3)
    }

    @Test func newerMessagesAndRepliesCountOnlyWhatTheTranscriptShows() {
        var state = catchUpTestState(users: [25])
        state.messages.append(ChannelMessage(id: "s31", sequence: 31, timestamp: "2026-10-22T12:00:00Z",
                                             sender: .system, content: .text("Joined")))
        #expect(TranscriptCatchUp.newerCount(in: state.messages, after: 20) == 9)
        #expect(TranscriptCatchUp.isReplied(24, in: state.messages))
        #expect(!TranscriptCatchUp.isReplied(25, in: state.messages))
    }

    @Test func imagesAreDescribedOnlyForVoiceOverAndOnlyOnce() async throws {
        let descriptions = TranscriptImageDescriptions(observesVoiceOver: false)
        let service = StubChannelIntelligence(descriptions: ["chart": "A chart of weekly signups rising."])
        #expect(!descriptions.isActive(using: service, isOn: true))
        descriptions.isVoiceOverRunning = true
        #expect(descriptions.isActive(using: service, isOn: true))
        #expect(!descriptions.isActive(using: service, isOn: false))
        #expect(!descriptions.isActive(using: StubChannelIntelligence(availability: .unavailable(.deviceNotEligible)),
                                       isOn: true))

        let request = describedImage("chart")
        #expect(descriptions.text(for: request) == nil)
        #expect(TranscriptImageDescriptions.value(descriptions.text(for: request)) == "")
        await descriptions.describe(request, using: service)
        #expect(TranscriptImageDescriptions.value(descriptions.text(for: request))
                == "Generated description: A chart of weekly signups rising.")
        // The viewer asks for the same image at a higher priority and finds it described.
        let focused = describedImage("chart", priority: .focused)
        #expect(descriptions.text(for: focused) == "A chart of weekly signups rising.")
        await descriptions.describe(focused, using: service)

        // An image the model can't describe isn't asked about again.
        await descriptions.describe(describedImage("photo"), using: service)
        await descriptions.describe(describedImage("photo"), using: service)
        #expect(descriptions.text(for: describedImage("photo")) == nil)
        #expect(service.altTextCount == 2)
    }

    @Test func aDescriptionGivenUpWhenItsTileScrollsAwayIsAskedForAgain() async throws {
        let descriptions = TranscriptImageDescriptions(observesVoiceOver: false)
        let slow = StubChannelIntelligence(delay: .seconds(30), descriptions: ["chart": "A chart."])
        let request = describedImage("chart")
        let task = Task { await descriptions.describe(request, using: slow) }
        try await transcriptUntil { slow.altTextCount > 0 }
        task.cancel()
        await task.value
        #expect(descriptions.text(for: request) == nil)

        await descriptions.describe(request, using: StubChannelIntelligence(descriptions: ["chart": "A chart."]))
        #expect(descriptions.text(for: request) == "A chart.")
    }

    private func describedImage(_ digest: String, priority: AltTextRequest.Priority = .visible) -> AltTextRequest {
        AltTextRequest(server: server, digest: digest, fileURL: URL(fileURLWithPath: "/tmp/\(digest).png"),
                       priority: priority)
    }

    @Test(.enabled(if: transcriptTimingTestsEnabled), arguments: [false, true])
    func aCardGrowingAboveTheViewportLeavesTheReaderInPlace(legacyScrollers: Bool) async throws {
        let ready = CatchUp(needsYou: nil, changes: (11...16).map {
            .init(text: "Lead moved update \($0) along, with enough detail to wrap the line.", sources: [$0])
        }, through: 40)
        let service = StubChannelIntelligence(results: [.ready(ready)], holdsCatchUp: true)
        let messages = (1...40).map { catchUpTestMessage($0, repeats: $0 > 9 ? 3 : 1) }
        let harness = try await TranscriptHarness(messages: messages, seenThrough: 9, height: 800,
                                                  legacyScrollers: legacyScrollers, intelligence: service)
        defer {
            service.releaseCatchUp()
            harness.close()
        }
        let clip = harness.scrollView.contentView
        if legacyScrollers { #expect(harness.scrollView.scrollerStyle == .legacy) }
        try await harness.waitUntil { harness.capture.hasLanded && service.catchUpCount == 1 }
        let divider = try #require(harness.capture.frames["divider-m10"]?.rect)
        try #require(divider.minY >= -0.5 && divider.minY < 120, "Landed with the divider at \(divider)")
        let landed = clip.bounds.minY
        try await harness.scrollDown(byWheel: false) { clip.bounds.minY > landed + 400 }
        let reading = harness.visibleFrames()
        try #require(reading.count >= 2)
        let height = harness.scrollView.documentView?.bounds.height ?? 0

        service.releaseCatchUp()
        try await harness.waitUntil { (harness.scrollView.documentView?.bounds.height ?? 0) > height + 40 }
        try await harness.settled()
        for (id, rect) in reading {
            let after = harness.capture.frames[id]?.rect ?? .null
            #expect(abs(after.minY - rect.minY) < 1, "\(id) moved from \(rect) to \(after)")
        }
        #expect(harness.readRequests == 0)
    }
}

@MainActor
private final class TranscriptOpeningLog {
    /// The unread divider's frame in each pass drawn with the rows showing.
    var drawn: [CGRect?] = []
    var hiddenTurns = 0
}

private final class StubChannelIntelligence: ChannelIntelligenceService {
    let availability: IntelligenceAvailability
    private let results: Mutex<[CatchUpResult]>
    private let descriptions: [String: String]
    private let delay: Duration
    private let calls = Mutex((catchUp: 0, altText: 0))
    private let hold: Mutex<(isHeld: Bool, waiting: [CheckedContinuation<Void, Never>])>

    /// `holdsCatchUp` keeps every catch-up answer waiting until `releaseCatchUp()`.
    init(availability: IntelligenceAvailability = .available, results: [CatchUpResult] = [],
         delay: Duration = .zero, holdsCatchUp: Bool = false, descriptions: [String: String] = [:]) {
        self.availability = availability
        self.results = Mutex(results)
        self.delay = delay
        hold = Mutex((holdsCatchUp, []))
        self.descriptions = descriptions
    }

    func releaseCatchUp() {
        let waiting = hold.withLock { hold in
            hold.isHeld = false
            defer { hold.waiting = [] }
            return hold.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    var catchUpCount: Int { calls.withLock { $0.catchUp } }
    var altTextCount: Int { calls.withLock { $0.altText } }

    /// Answers with each result in turn, then keeps answering with the last.
    func catchUp(_ request: CatchUpRequest) async -> CatchUpResult {
        calls.withLock { $0.catchUp += 1 }
        await withCheckedContinuation { continuation in
            let isHeld = hold.withLock { hold in
                if hold.isHeld { hold.waiting.append(continuation) }
                return hold.isHeld
            }
            if !isHeld { continuation.resume() }
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return results.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? .declined }
    }

    func altText(_ request: AltTextRequest) async -> AltText? {
        calls.withLock { $0.altText += 1 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return descriptions[request.digest].map(AltText.init(text:))
    }
}

func catchUpTestMessage(_ sequence: Int, sender: ChannelMessageSender = .agent("lead"),
                        repeats: Int = 1) -> ChannelMessage {
    let sentence = "Update \(sequence) moves the launch checklist forward, with the reconnect fix verified and "
        + "the badge holding at zero unread."
    return ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T12:00:00Z", sender: sender,
                          content: .text(Array(repeating: sentence, count: repeats).joined(separator: " ")))
}

func catchUpTestState(through latest: Int = 30, seenThrough: Int = 10, users: Set<Int> = []) -> ChannelState {
    let channel = Channel(id: "catch-up", name: "Catch-up", model: .init(provider: "test", name: "test"),
                          latestSequence: latest, seenThrough: seenThrough, updatedAt: "2026-10-22T12:00:00Z")
    return ChannelState(revision: 1, channel: channel, lead: .lead(id: "lead"), messages: (1...latest).map {
        catchUpTestMessage($0, sender: users.contains($0) ? .user : .agent("lead"))
    })
}

func transcriptTestMessage(_ sequence: Int) -> ChannelMessage {
    ChannelMessage(id: "m\(sequence)", sequence: sequence, timestamp: "2026-10-22T12:00:00Z",
                   sender: .agent("lead"),
                   content: .text("Update \(sequence) has enough words to wrap onto a second line here."))
}

/// Separate lazy rows keep this fixture's initial window-space measurements independently settled.
func transcriptFindTestMessages(_ sequences: ClosedRange<Int>) -> [ChannelMessage] {
    sequences.map { sequence in
        var message = transcriptTestMessage(sequence)
        if sequence.isMultiple(of: 2) { message.sender = .user }
        return message
    }
}

/// Heights from 480 out by `count` steps and back again, like dragging the bottom edge and returning.
func transcriptResizeSteps(by step: CGFloat, count: Int) -> [CGFloat] {
    let out = (1...count).map { 480 + CGFloat($0) * step }
    return out + out.dropLast().reversed() + [480]
}

/// Hosts the real transcript against an in-memory channel server. The window never becomes key, so
/// the transcript must never acknowledge what it shows.
@MainActor
private final class TranscriptHarness {
    let host: String
    let store: ChannelStore
    let interaction: ChannelInteraction
    let capture: TranscriptLayoutCapture
    private(set) var scrollView = NSScrollView()
    private let session: URLSession
    private let window: NSWindow
    private var turnObserver: CFRunLoopObserver?
    private var onTurn: (@MainActor (TranscriptHarness) -> Void)?

    /// Lands at the bottom unless `seenThrough` leaves messages unread, in which case it lands at the first.
    /// A `resizable` transcript fills the window, so `resize(height:)` reaches it the way a live resize does.
    /// A `warm` store is live before the transcript appears, as when switching back to a channel.
    /// `onTurn` runs after every layout and display pass from the first one on.
    init(messages: [ChannelMessage], history: [ChannelMessage] = [], holdsHistory: Bool = false,
         seenThrough: Int? = nil, height: CGFloat = 480, resizable: Bool = false, warm: Bool = false,
         legacyScrollers: Bool = false,
         intelligence: any ChannelIntelligenceService = LiveChannelIntelligence.shared,
         find: TranscriptFind = TranscriptFind(),
         onTurn: (@MainActor (TranscriptHarness) -> Void)? = nil) async throws {
        let host = "transcript-\(UUID().uuidString.lowercased()).invalid"
        let latest = messages.last?.sequence ?? 0
        let channel = Channel(id: "harness", name: "Harness", model: .init(provider: "test", name: "test"),
                              latestSequence: latest, seenThrough: seenThrough ?? latest,
                              updatedAt: "2026-10-22T12:00:00Z")
        let snapshot = try TranscriptServerProtocol.event(.init(type: "snapshot", state: ChannelState(
            revision: 1, channel: channel, lead: .lead(id: "lead"), messages: messages)))
        TranscriptServerProtocol.fixtures.withLock {
            $0[host] = .init(snapshot: snapshot, history: history, holdsHistory: holdsHistory)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranscriptServerProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = ChannelStore(id: "harness", api: try ChannelAPI(serverURL: "https://\(host)", session: session),
                                 sendJournal: nil)
        let interaction = ChannelInteraction()
        let capture = TranscriptLayoutCapture()
        if warm {
            store.connect()
            let deadline = ContinuousClock.now + .seconds(60)
            while !(store.isLoaded && store.phase.isLive), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(store.isLoaded && store.phase.isLive)
        }
        let view = NSHostingView(rootView: ConversationTranscript(store: store, find: find)
            .onPreferenceChange(TranscriptMessageFrames.self) { capture.frames = $0 }
            .onPreferenceChange(TranscriptLanded.self) { capture.hasLanded = $0 }
            .onPreferenceChange(TranscriptRestoringHistory.self) { capture.isRestoringHistory = $0 }
            .safeAreaBar(edge: .bottom, spacing: 0) { Color.clear.frame(height: 100) }
            .environment(interaction)
            .environment(ArtifactOpener())
            .environment(\.channelIntelligence, intelligence)
            .frame(width: resizable ? nil : 520, height: resizable ? nil : height))
        if resizable { view.sizingOptions = [] }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        (self.host, self.store, self.interaction, self.capture) = (host, store, interaction, capture)
        (self.session, self.window) = (session, window)
        if let onTurn {
            self.onTurn = onTurn
            // After Core Animation's commit, so it sees each pass as drawn.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                              CFIndex.max) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { self.onTurn?(self) } }
            }
            turnObserver = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        func findScrollView(in view: NSView) -> NSScrollView? {
            view as? NSScrollView ?? view.subviews.lazy.compactMap(findScrollView(in:)).first
        }
        if !warm { store.connect() }
        if legacyScrollers {
            try await waitUntil { findScrollView(in: view) != nil }
            try #require(findScrollView(in: view)).scrollerStyle = .legacy
        }
        try await waitUntil { findScrollView(in: view)?.documentView.map { $0.bounds.height > 800 } == true }
        scrollView = try #require(findScrollView(in: view))
        if let seenThrough, seenThrough < latest {
            try await waitUntil { capture.hasLanded }
        } else {
            try await waitUntil { capture.hasLanded && abs(self.bottomGap) < 2 }
            try await settled()
        }
    }

    var bottomGap: CGFloat {
        (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.maxY
            + scrollView.contentInsets.bottom
    }

    var readRequests: Int {
        TranscriptServerProtocol.fixtures.withLock { $0[host]?.requests.filter { $0.hasSuffix("/read") }.count ?? 0 }
    }

    var frames: [String: TranscriptMessageFrame] {
        let top = scrollView.contentView.bounds.minY + scrollView.contentInsets.top
        return capture.frames.mapValues { TranscriptCoordinates.viewportFrame($0, top: top) }
    }

    var windowFrames: [String: CGRect] {
        capture.frames.mapValues(\.windowRect)
    }

    var findField: NSSearchField? {
        func find(in view: NSView) -> NSSearchField? {
            view as? NSSearchField ?? view.subviews.lazy.compactMap(find(in:)).first
        }
        return window.contentView.flatMap(find(in:))
    }

    func visibleWindowFrames() -> [String: CGRect] {
        windowFrames.filter { id, rect in
            capture.frames[id]?.sequence ?? 0 > 0 && rect.minY >= 0 && rect.maxY <= window.contentLayoutRect.height - 100
        }
    }

    func isVisible(_ id: String) -> Bool {
        guard let rect = frames[id]?.rect else { return false }
        return isVisible(rect)
    }

    private func isVisible(_ rect: CGRect) -> Bool {
        return rect.minY >= 0 && rect.maxY <= scrollView.contentView.bounds.height - scrollView.contentInsets.bottom
    }

    /// Frames of the messages wholly inside the unobscured viewport. Dividers come and go as pages join runs.
    func visibleFrames() -> [String: CGRect] {
        frames.reduce(into: [:]) { result, entry in
            if entry.value.sequence > 0, isVisible(entry.value.rect) { result[entry.key] = entry.value.rect }
        }
    }

    /// The rows' opacity as drawn. SwiftUI applies it to the views hosting the rows' window probe.
    var rowsOpacity: CGFloat {
        func probe(in view: NSView) -> NSView? {
            view is TranscriptWindowProbe.ProbeView ? view : view.subviews.lazy.compactMap(probe(in:)).first
        }
        var view = window.contentView.flatMap(probe(in:))
        guard view != nil else { return 0 }
        var opacity: CGFloat = 1
        while let current = view {
            opacity *= current.isHidden ? 0 : current.alphaValue
            view = current.superview
        }
        return opacity
    }

    /// Waits up to a deadline rather than a count of cycles, since a starved runner stretches each cycle.
    func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        try await transcriptUntil(in: window.contentView, sourceLocation: sourceLocation, failure: {
            "Transcript landed: \(self.capture.hasLanded), gap: \(self.bottomGap), "
                + "clip: \(self.scrollView.contentView.bounds), "
                + "document: \(String(describing: self.scrollView.documentView?.bounds))"
        }, condition)
    }

    func frame() async throws {
        try await transcriptFrame(in: try #require(window.contentView))
    }

    func settled() async throws {
        struct Layout: Equatable {
            var frames: [String: TranscriptMessageFrame]
            var clip: CGRect
            var document: CGRect?
        }
        try await transcriptSettled(in: try #require(window.contentView)) {
            Layout(frames: capture.frames, clip: scrollView.contentView.bounds,
                   document: scrollView.documentView?.bounds)
        }
    }

    /// AppKit ignores synthesized wheel events while the screen is locked or the display sleeps.
    static var wheelEventsApply: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool != true && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    /// Scrolls toward older messages one mouse wheel notch at a time, or by dragging the scroller: AppKit
    /// moves the clip view between live-scroll notifications, which SwiftUI reports as an interaction.
    func scrollUp(byWheel: Bool, until condition: () -> Bool) async throws {
        try await scroll(towardOlder: true, byWheel: byWheel, until: condition)
    }

    func scrollDown(byWheel: Bool, until condition: () -> Bool) async throws {
        try await scroll(towardOlder: false, byWheel: byWheel, until: condition)
    }

    private func scroll(towardOlder: Bool, byWheel: Bool, until condition: () -> Bool) async throws {
        let clip = scrollView.contentView
        let deadline = ContinuousClock.now + .seconds(60)
        if byWheel {
            while !condition(), ContinuousClock.now < deadline {
                let notch = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                                 wheel1: towardOlder ? 3 : -3, wheel2: 0, wheel3: 0))
                scrollView.scrollWheel(with: try #require(NSEvent(cgEvent: notch)))
                try await frame()
            }
        } else {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            while !condition(), ContinuousClock.now < deadline {
                let y = towardOlder ? clip.bounds.minY - 30 : clip.bounds.minY + 30
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(-scrollView.contentInsets.top, y)))
                scrollView.reflectScrolledClipView(clip)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
                try await frame()
            }
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        }
        try #require(condition(), "Stopped at \(clip.bounds.minY) with a gap of \(bottomGap)")
        try await settled()
    }

    /// Moves the bottom or right edge as dragging it does: AppKit lays out and draws the new size synchronously.
    func resize(width: CGFloat? = nil, height: CGFloat? = nil) {
        let frame = window.frame
        let size = CGSize(width: width ?? frame.width, height: height ?? frame.height)
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                        display: true)
    }

    func push(_ message: ChannelMessage, revision: Int) {
        let event = try? TranscriptServerProtocol.event(.init(type: "message", revision: revision, message: message))
        let stream = TranscriptServerProtocol.fixtures.withLock { $0[host]?.stream }
        if let event { stream?.deliver(event) }
    }

    func releaseHistory() {
        let held = TranscriptServerProtocol.fixtures.withLock { fixtures in
            defer { fixtures[host]?.held = [] }
            return fixtures[host]?.held ?? []
        }
        for response in held { response.request.finish(with: response.body) }
    }

    func close() {
        if let turnObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), turnObserver, .commonModes) }
        turnObserver = nil
        store.disconnect()
        window.close()
        session.invalidateAndCancel()
        TranscriptServerProtocol.fixtures.withLock { _ = $0.removeValue(forKey: host) }
    }
}

/// An in-memory channel server: a snapshot stream that stays open for pushed events, history pages
/// that can be held until released, and a 503 for every write, like an unavailable server.
private final class TranscriptServerProtocol: URLProtocol, @unchecked Sendable {
    struct HeldResponse: Sendable {
        var request: TranscriptServerProtocol
        var body: Data
    }

    struct Fixture: Sendable {
        var snapshot: Data
        var history: [ChannelMessage]
        var holdsHistory: Bool
        var stream: TranscriptServerProtocol?
        var held: [HeldResponse] = []
        var requests: [String] = []
    }

    static let fixtures = Mutex<[String: Fixture]>([:])

    static func event(_ event: ChannelObservationEvent) throws -> Data {
        Data(("data: " + String(decoding: try JSONEncoder().encode(event), as: UTF8.self) + "\n\n").utf8)
    }

    private var thread: Thread?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        thread = .current
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let streaming = method == "GET" && request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
        let before = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "before" }?.value.flatMap { Int($0) }
        let page: Data? = Self.fixtures.withLock { fixtures in
            guard let before, let history = fixtures[host]?.history else { return nil }
            let messages = Array(history.filter { $0.sequence < before }.suffix(30))
            let encoded = String(decoding: (try? JSONEncoder().encode(messages)) ?? Data(), as: UTF8.self)
            return Data(#"{"version":1,"revision":1,"messages":\#(encoded)}"#.utf8)
        }
        enum Reply { case stream(Data), page(Data), held, unavailable, missing }
        let reply = Self.fixtures.withLock { fixtures -> Reply in
            guard var fixture = fixtures[host] else { return .missing }
            defer { fixtures[host] = fixture }
            fixture.requests.append("\(method) \(url.path)")
            if streaming {
                fixture.stream = self
                return .stream(fixture.snapshot)
            }
            guard method == "GET", url.lastPathComponent == "messages", let page else { return .unavailable }
            guard fixture.holdsHistory else { return .page(page) }
            fixture.held.append(.init(request: self, body: page))
            return .held
        }
        switch reply {
        case .missing: client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .stream(let snapshot):
            respond(status: 200, type: "text/event-stream")
            client?.urlProtocol(self, didLoad: snapshot)
        case .page(let body): respond(status: 200, body: body)
        case .held: break
        case .unavailable: respond(status: 503, body: Data(#"{"error":"The server is unavailable."}"#.utf8))
        }
    }

    override func stopLoading() {}

    /// Loading callbacks must arrive on the thread that started loading.
    func deliver(_ data: Data) {
        guard let thread else { return }
        perform(#selector(load(_:)), on: thread, with: data as NSData, waitUntilDone: false,
                modes: [RunLoop.Mode.common.rawValue])
    }

    func finish(with body: Data) {
        guard let thread else { return }
        perform(#selector(finishLoading(_:)), on: thread, with: body as NSData, waitUntilDone: false,
                modes: [RunLoop.Mode.common.rawValue])
    }

    @objc private func load(_ data: NSData) { client?.urlProtocol(self, didLoad: data as Data) }
    @objc private func finishLoading(_ body: NSData) { respond(status: 200, body: body as Data) }

    private func respond(status: Int, type: String = "application/json", body: Data? = nil) {
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body {
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}


/// One long agent message, hovered by calling its tracking methods
/// directly, since a test's posted moves never reach SwiftUI's hover tracking.
@MainActor
private final class HoveredMessage {
    let host: NSView
    /// Its own, as each transcript has, so another test's scrolling never holds this message back.
    let pointer = TranscriptPointer()
    private let window: NSWindow
    private let tableCoordinator: TranscriptTablePrototype.Coordinator?
    var tableView: NSTableView? { tableCoordinator?.table }

    init(id: String, table: Bool = false) async throws {
        pointer.location = { .zero }
        let lead = ChannelAgent.lead(id: "lead")
        let store = ChannelStore(id: "selection", api: try ChannelAPI(serverURL: "https://selection.invalid"),
                                 sendJournal: nil)
        let message = ChannelMessage(id: id, sequence: 1, timestamp: "2026-10-22T10:00:00Z", sender: .agent("lead"),
                                     content: .text(String(repeating: "A paragraph long enough to wrap. ", count: 6)
                                         + "\n\nA second paragraph."))
        let row = try #require(transcriptRows([message], lead: lead, members: []).last)
        let context = TranscriptRowContext(agents: [lead], channelID: "selection", historyStart: 1, api: store.api)
        if table {
            let coordinator = TranscriptTablePrototype.Coordinator()
            tableCoordinator = coordinator
            let scroll = TranscriptTableScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            scroll.automaticallyAdjustsContentInsets = false
            coordinator.attach(scroll)
            var environment = EnvironmentValues()
            environment[ChannelInteraction.self] = ChannelInteraction()
            environment[ArtifactOpener.self] = ArtifactOpener()
            environment.transcriptPointer = pointer
            let items = TranscriptTableItem.project([row])
            let content = items.map {
                TranscriptRowContent(row: $0.row, context: context, statusReactions: [:], highlightedSequence: nil,
                                     catchUp: nil, store: store, expandedMessageIds: [],
                                     showsAgentAvatar: $0.showsAvatar, onSetExpanded: { _, _ in })
            }
            coordinator.update(items: items, content: content, header: AnyView(EmptyView()),
                               environment: environment, insets: EdgeInsets())
            host = scroll
        } else {
            tableCoordinator = nil
            host = NSHostingView(rootView:
                TranscriptRowContent(row: row, context: context, statusReactions: [:], highlightedSequence: nil,
                                     catchUp: nil, store: store, expandedMessageIds: [], onSetExpanded: { _, _ in })
                    .padding(20)
                    .frame(width: 600, height: 300, alignment: .topLeading)
                    .coordinateSpace(name: "transcript-viewport")
                    .environment(\.transcriptPointer, pointer)
                    .environment(ChannelInteraction()))
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless],
                           backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await settled()
    }

    func platformViews() -> Int {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(host).count
    }

    /// Waits on the result rather than a fixed delay, which a starved test runner can outlast.
    func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        try await transcriptUntil(in: host, sourceLocation: sourceLocation, condition)
    }

    func settled() async throws {
        try await transcriptSettled(in: host, reading: platformViews)
    }

    func movePointer(x: CGFloat = 120) throws {
        let target = try trackingHost()
        target.mouseEntered(with: try hover(x: x))
        target.mouseMoved(with: try hover(x: x))
    }

    func leavePointer() throws {
        try trackingHost().mouseExited(with: hover())
    }

    private func trackingHost() throws -> NSView {
        guard let tableView else { return host }
        let cell = try #require(tableView.view(atColumn: 0, row: 1, makeIfNecessary: false))
        return try #require(cell.subviews.first)
    }

    func textUnderPointer() throws -> NSView {
        let event = try hover()
        let point = host.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        return try #require(host.hitTest(point))
    }

    /// A pointer event over the message's text. Each move needs its own point, since SwiftUI ignores
    /// a hover that doesn't move.
    func hover(x: CGFloat = 120) throws -> NSEvent {
        try pointerEvent(.mouseMoved, x: x)
    }

    func press() throws -> NSEvent {
        try pointerEvent(.leftMouseDown, x: 120)
    }

    private func pointerEvent(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
        let target = try trackingHost()
        let local = CGPoint(x: x, y: target.isFlipped ? 92 : target.bounds.height - 92)
        return try #require(NSEvent.mouseEvent(
            with: type, location: target.convert(local, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
    }

    func close() { window.close() }
}

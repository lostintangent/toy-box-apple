import AppKit
import ChannelKit
import SwiftUI

struct TranscriptTablePrototype: NSViewControllerRepresentable {
    static let isEnabled = ProcessInfo.processInfo.environment["TOY_BOX_TRANSCRIPT"] == "table"

    let items: [TranscriptTableItem]
    let content: [TranscriptRowContent]
    let header: AnyView
    let insets: EdgeInsets

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> TranscriptTableEdges {
        let scroll = TranscriptTableScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = true
        context.coordinator.attach(scroll)
        return TranscriptTableEdges(content: scroll)
    }

    func updateNSViewController(_ controller: TranscriptTableEdges, context: Context) {
        controller.update(top: insets.top, bottom: insets.bottom)
        context.coordinator.update(items: items, content: content, header: header,
                                   environment: context.environment, insets: insets)
    }

    static func dismantleNSViewController(_ controller: TranscriptTableEdges, coordinator: Coordinator) {
        controller.stopEdgeTrace()
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private struct Configuration {
            let items: [TranscriptTableItem]
            let content: [TranscriptRowContent]
            let header: AnyView
            let footer: AnyView?
            let environment: EnvironmentValues
            let insets: EdgeInsets
            let isReadyToLand: Bool
            let holdsPosition: Bool
            let onReaderScroll: ((Bool) -> Void)?
        }

        private struct NativeGeometry: Equatable {
            let clipSize: NSSize
            let topInset: CGFloat
            let bottomInset: CGFloat
        }

        private typealias Model = TranscriptScrollModel
        private static let headerID = "transcript-history-header"
        private static let footerID = "transcript-pending-sends"
        private static let retainedCellLimit = 128
        let table = TranscriptTableView()
        private weak var scroll: NSScrollView?
        private weak var document: NSView?
        private weak var state: TranscriptDocumentState?
        private var ownsDocument = true
        private let cache = TranscriptTableHeights()
        private var items: [TranscriptTableItem] = []
        private var content: [TranscriptRowContent] = []
        private var header = AnyView(EmptyView())
        private var footer: AnyView?
        private var environment = EnvironmentValues()
        private var heights: [CGFloat] = []
        private var overflows: [Bool?] = []
        private var headerHeight: CGFloat = 20
        private var footerHeight: CGFloat = 0
        private var appliedAccessoryHeights: [String: CGFloat] = [:]
        private var appliedWidth: CGFloat = 0
        private var isDirty = false
        private var isLayingOut = false
        private var isReaderScrolling = false
        private var isHandlingReaderInput = false
        private var hasLanded = false
        private var pendingReaderPages: [Bool] = []
        private var jumpAnimation: TranscriptScrollAnimation?
        private var stopsNativeScroll = false
        private var hasLoadedTable = false
        private var intent: Model.Intent = .landing(.end)
        private var pendingEvents: [Model.Event] = []
        private var lastCommand: UUID?
        private var pendingResume = false
        private var frames: [Model.RowFrame] = []
        private var viewport: Model.Viewport?
        private var observedBounds: NSRect?
        private var laidOutNativeGeometry: NativeGeometry?
        private var notifications: [NSObjectProtocol] = []
        private var insetObservation: NSKeyValueObservation?
        private var insetChangeDepth = 0
        private var accessoryNeedsMeasurement = true
        private var sizingWidth: CGFloat = 0
        private(set) var messageFrames: [String: [String: TranscriptMessageFrame]] = [:]
        private var invalidatedCells: Set<String> = []
        private var cachedCells: [String: TranscriptTableCell] = [:]
        private var recentCellIDs: [String] = []
        private var isRefiningHeights = false
        private var configuration: Configuration?
        private(set) var documentHeight: CGFloat = 0
        private(set) var reusedCellCount = 0
        var scrollIntent: TranscriptScrollModel.Intent { intent }
        var isAnimatingJump: Bool { jumpAnimation != nil }
        var measurementCount: Int { cache.measurementCount }
        var retainedCellCount: Int { cachedCells.count }

        override init() {
            super.init()
            table.headerView = nil
            table.style = .plain
            table.backgroundColor = .clear
            table.intercellSpacing = .zero
            table.selectionHighlightStyle = .none
            table.focusRingType = .none
            table.usesAutomaticRowHeights = false
            table.usesAlternatingRowBackgroundColors = false
            table.allowsColumnReordering = false
            table.allowsColumnResizing = false
            table.allowsTypeSelect = false
            table.columnAutoresizingStyle = .noColumnAutoresizing
            let column = NSTableColumn(identifier: .init("transcript"))
            column.minWidth = 0
            column.maxWidth = .greatestFiniteMagnitude
            table.addTableColumn(column)
            table.dataSource = self
            table.delegate = self
            table.coordinator = self
        }

        func attach(_ scroll: NSScrollView, ownsDocument: Bool = true, document: NSView? = nil) {
            stopObserving()
            self.scroll = scroll
            self.document = document
            self.ownsDocument = ownsDocument
            if let native = scroll as? TranscriptTableScrollView { native.coordinator = self }
            if ownsDocument { scroll.documentView = table }
            let clip = scroll.contentView
            observedBounds = clip.bounds
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            notifications.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
            })
            notifications.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: clip, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestLayout() }
            })
            insetObservation = scroll.observe(\.contentInsets, options: [.prior]) { [weak self] _, change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.insetChangeDepth += change.isPrior ? 1 : -1
                    if !change.isPrior { self.requestLayout() }
                }
            }
        }

        func fittingHeight(items: [TranscriptTableItem], content: [TranscriptRowContent], header: AnyView,
                           width: CGFloat, environment: EnvironmentValues, footer: AnyView? = nil) -> CGFloat {
            let result = measuredGeometry(items: items, content: content, header: header,
                                          footer: footer, width: width, environment: environment)
            documentHeight = Model.end(rowFrames(items: items, heights: result.heights, hasFooter: footer != nil))
            return documentHeight
        }

        func layoutWidth(proposed: CGFloat) -> CGFloat {
            guard !ownsDocument, let scroll else { return proposed }
            return max(0, proposed - scroll.contentInsets.left - scroll.contentInsets.right)
        }

        func update(items: [TranscriptTableItem], content: [TranscriptRowContent], header: AnyView,
                    environment: EnvironmentValues, insets: EdgeInsets,
                    state: TranscriptDocumentState? = nil, isReadyToLand: Bool = true, footer: AnyView? = nil,
                    holdsPosition: Bool = false, onReaderScroll: ((Bool) -> Void)? = nil) {
            let previouslyHeld = configuration?.holdsPosition ?? false
            configuration = Configuration(items: items, content: content, header: header,
                                          footer: footer, environment: environment, insets: insets,
                                          isReadyToLand: isReadyToLand, holdsPosition: holdsPosition,
                                          onReaderScroll: onReaderScroll)
            if environment.accessibilityReduceMotion, jumpAnimation != nil {
                request(.jumpToLatest)
            }
            if previouslyHeld != holdsPosition {
                if holdsPosition {
                    cancelJumpAnimation(capturingPosition: false)
                    pendingReaderPages.removeAll()
                    pendingResume = false
                    if hasLanded, let viewport {
                        intent = Model.reduce(intent, .holdCurrentPosition, rows: frames,
                                              viewport: viewport, origin: nativeOrigin).intent
                    } else { pendingEvents.append(.holdCurrentPosition) }
                } else { pendingResume = true }
            }
            if self.state !== state {
                self.state?.cancelPublication()
                self.state = state
                state?.attach(self)
            }
            accessoryNeedsMeasurement = true
            isDirty = true
            requestLayout()
        }

        func accept(_ command: TranscriptDocumentState.Command?) {
            guard let command, command.token != lastCommand else { return }
            lastCommand = command.token
            request(command.event)
        }

        func captureExpansion(_ event: TranscriptScrollModel.Event) -> Bool {
            guard let viewport else { return false }
            cancelJumpAnimation(capturingPosition: false)
            let placement = Model.reduce(intent, event, rows: frames, viewport: viewport, origin: nativeOrigin)
            guard placement.unavailableTarget == nil else { return false }
            intent = placement.intent
            return true
        }

        private func request(_ event: TranscriptScrollModel.Event) {
            cancelJumpAnimation(capturingPosition: false)
            pendingReaderPages.removeAll()
            if event == .jumpToLatest, hasLanded, let viewport {
                stopsNativeScroll = true
                let reducesMotion = configuration?.environment.accessibilityReduceMotion
                    ?? environment.accessibilityReduceMotion
                if TranscriptScrollAnimation.shouldAnimate(
                    reducesMotion: reducesMotion, distance: Model.distanceToEnd(nativeOrigin, rows: frames, viewport: viewport)
                ) {
                    let start = Model.reduce(intent, .holdCurrentPosition, rows: frames,
                                             viewport: viewport, origin: nativeOrigin).intent
                    let animation = TranscriptScrollAnimation(
                        start: start, framesPerSecond: table.window?.screen?.maximumFramesPerSecond ?? 60
                    ) { [weak self] in self?.requestLayout() }
                    jumpAnimation = animation
                    animation.start()
                }
            }
            pendingEvents.append(event)
            requestLayout()
        }

        private func cancelJumpAnimation(capturingPosition: Bool) {
            let hadJump = jumpAnimation != nil || stopsNativeScroll
            jumpAnimation?.stop()
            jumpAnimation = nil
            stopsNativeScroll = false
            if hadJump {
                pendingEvents.removeAll { $0 == .jumpToLatest }
                if capturingPosition, let viewport {
                    intent = Model.reduce(intent, .readerScrolled(to: nativeOrigin), rows: frames,
                                          viewport: viewport, origin: nativeOrigin).intent
                }
            }
        }

        private var nativeOrigin: CGFloat {
            guard let clip = scroll?.contentView else { return 0 }
            return table.convert(clip.bounds.origin, from: clip).y
        }

        private func currentViewport(width: CGFloat) -> Model.Viewport {
            let insets = scroll?.contentInsets ?? .init()
            return Model.Viewport(width: width, height: scroll?.contentView.bounds.height ?? 0,
                                  topInset: max(0, insets.top), bottomInset: max(0, insets.bottom))
        }

        private func rowFrames(items: [TranscriptTableItem], heights: [CGFloat],
                               hasFooter: Bool) -> [Model.RowFrame] {
            if items == self.items, heights == self.heights, hasFooter == (footer != nil),
               appliedAccessoryHeights[Self.headerID] == headerHeight,
               appliedAccessoryHeights[Self.footerID] == footerHeight {
                return frames
            }
            var result = [Model.RowFrame(id: Self.headerID, order: Int.min, top: 0,
                                         height: headerHeight, isAnchorable: false)]
            result.reserveCapacity(items.count + 2)
            var top = headerHeight
            for (index, item) in items.enumerated() {
                result.append(Model.RowFrame(id: item.id, order: item.order,
                                             top: top, height: heights[index]))
                top += heights[index]
            }
            if hasFooter {
                result.append(Model.RowFrame(id: Self.footerID, order: Int.max, top: top,
                                             height: footerHeight, isAnchorable: false))
            }
            return result
        }

        private func measuredGeometry(items: [TranscriptTableItem], content: [TranscriptRowContent],
                                      header: AnyView, footer: AnyView?, width: CGFloat,
                                      environment: EnvironmentValues) -> TranscriptTableHeights.Result {
            refineLiveHeights(width: width, environment: environment)
            if accessoryNeedsMeasurement || sizingWidth != width {
                headerHeight = 20 + cache.measureAccessory(header, width: width, environment: environment)
                footerHeight = footer.map {
                    cache.measureAccessory(AnyView($0.modifier(ConversationRail())), width: width,
                                           environment: environment)
                } ?? 0
                accessoryNeedsMeasurement = false
                sizingWidth = width
            }
            let viewport = currentViewport(width: width)
            var result = cache.resolve(items: items, content: content, width: width,
                                       environment: environment, measuring: IndexSet())
            while true {
                let frames = rowFrames(items: items, heights: result.heights, hasFooter: footer != nil)
                let placement = proposedPlacement(rows: frames, viewport: viewport)
                let origin = placement?.origin ?? nativeOrigin
                let page = pendingReaderPages.first.map {
                    ($0 ? -1 : 1) * max(0, viewport.unobscuredHeight - (scroll?.verticalPageScroll ?? 0))
                } ?? 0
                let top = origin + viewport.topInset + min(0, page) - viewport.unobscuredHeight / 2
                let bottom = origin + viewport.height - viewport.bottomInset
                    + max(0, page) + viewport.unobscuredHeight / 2
                // Warm two viewport bands, never the history between a Jump's endpoints.
                let destination: CGFloat? = jumpAnimation == nil ? nil
                    : Model.placement(for: .following, rows: frames, viewport: viewport).origin
                var requested = IndexSet()
                for index in items.indices {
                    let frame = frames[index + 1]
                    let inView = frame.bottom >= top && frame.top <= bottom
                    let atDestination = destination.map {
                        frame.bottom >= $0 + viewport.topInset - viewport.unobscuredHeight / 2
                            && frame.top <= $0 + viewport.height - viewport.bottomInset + viewport.unobscuredHeight / 2
                    } ?? false
                    if inView || atDestination { requested.insert(index) }
                }
                let missing = requested.subtracting(result.exactIndexes)
                guard !missing.isEmpty else { return result }
                result = cache.resolve(items: items, content: content, width: width,
                                       environment: environment, measuring: missing)
            }
        }

        private func refineLiveHeights(width: CGFloat, environment: EnvironmentValues) {
            guard !isRefiningHeights else { return }
            isRefiningHeights = true
            defer { isRefiningHeights = false }
            let invalidated = invalidatedCells
            invalidatedCells.removeAll()
            for id in invalidated {
                guard let index = items.firstIndex(where: { $0.id == id }),
                      let cell = table.view(atColumn: 0, row: index + 1,
                                            makeIfNecessary: false) as? TranscriptTableCell,
                      cell.representedID == id,
                      cell.measuredEnvironment == TranscriptTableHeights.Environment(width: width,
                                                                                    values: environment)
                else { continue }
                let intrinsic = cell.host.intrinsicContentSize.height
                guard intrinsic > 0, intrinsic.isFinite else { continue }
                let height = ceil(intrinsic * environment.displayScale) / environment.displayScale
                if heights[index] != height {
                    cache.recordLiveHeight(height, item: items[index], content: content[index], width: width,
                                           environment: environment, overflows: overflows[index])
                }
            }
        }

        private func proposedPlacement(rows: [Model.RowFrame], viewport: Model.Viewport) -> Model.Placement? {
            var intent = intent
            var origin: CGFloat?
            var unavailable: String?
            var receivedEvent = false
            func apply(_ event: Model.Event) {
                let result = Model.reduce(intent, event, rows: rows, viewport: viewport, origin: origin ?? nativeOrigin)
                intent = result.intent
                if let placement = result.origin { origin = placement }
                unavailable = result.unavailableTarget
                receivedEvent = true
            }
            if !hasLanded {
                guard configuration?.isReadyToLand == true else { return nil }
                let target = configuration?.items.first { $0.row.divider?.unread == true }
                let landing: Model.Target = target.map {
                    .row($0.id, order: $0.row.messages.first?.sequence ?? 0)
                } ?? .end
                apply(.land(landing))
            }
            for event in pendingEvents { apply(event) }
            if !receivedEvent, let oldViewport = self.viewport,
               let event = Model.layoutEvent(from: frames, viewport: oldViewport, to: rows, viewport: viewport) {
                apply(event)
            }
            if let animation = jumpAnimation {
                return TranscriptScrollAnimation.placement(from: animation.startIntent, to: intent,
                                                          progress: animation.progress, rows: rows, viewport: viewport)
            }
            return receivedEvent ? Model.Placement(intent: intent, origin: origin, unavailableTarget: unavailable) : nil
        }

        private func requestLayout() {
            if let document { document.needsLayout = true }
            else { scroll?.needsLayout = true }
        }

        private func nativeGeometry() -> NativeGeometry? {
            guard let scroll else { return nil }
            return NativeGeometry(clipSize: scroll.contentView.bounds.size,
                                  topInset: scroll.contentInsets.top, bottomInset: scroll.contentInsets.bottom)
        }

        func readerPhaseChanged(_ phase: ScrollPhase) {
            if phase == .tracking { pendingReaderPages.removeAll() }
            let wasScrolling = isReaderScrolling
            isReaderScrolling = phase != .idle
            guard wasScrolling != isReaderScrolling, hasLanded, let viewport else { return }
            if isReaderScrolling {
                cancelJumpAnimation(capturingPosition: false)
                pendingResume = false
                intent = Model.reduce(intent, .holdCurrentPosition, rows: frames,
                                      viewport: viewport, origin: nativeOrigin).intent
            } else {
                pendingResume = configuration?.holdsPosition != true
            }
            requestLayout()
        }

        func performReaderInput(_ action: () -> Void) {
            cancelJumpAnimation(capturingPosition: true)
            pendingReaderPages.removeAll()
            let wasHandlingInput = isHandlingReaderInput
            isHandlingReaderInput = true
            defer { isHandlingReaderInput = wasHandlingInput }
            action()
        }

        func prepareReaderPage(towardOlder: Bool) {
            cancelJumpAnimation(capturingPosition: true)
            pendingReaderPages.append(towardOlder)
            requestLayout()
        }

        private func forwardPreparedReaderPage() {
            guard let scroll, let towardOlder = pendingReaderPages.first,
                  abs((scroll.documentView?.bounds.height ?? 0) - documentHeight) <= 0.5 else { return }
            pendingReaderPages.removeFirst()
            if towardOlder { scroll.pageUp(table) }
            else { scroll.pageDown(table) }
            if !pendingReaderPages.isEmpty { requestLayout() }
        }

        private func boundsChanged() {
            guard let clip = scroll?.contentView else { return }
            let bounds = clip.bounds
            let previous = observedBounds
            observedBounds = bounds
            if previous?.origin != bounds.origin { environment.transcriptPointer?.contentDidMove() }
            guard hasLanded, !isLayingOut, let previous, previous.origin.y != bounds.origin.y else {
                requestLayout()
                return
            }
            let constrained = clip.constrainBoundsRect(NSRect(origin: previous.origin, size: bounds.size))
            if abs(constrained.minY - previous.minY) > 0.5,
               abs(constrained.minY - bounds.minY) <= 0.5 {
                requestLayout()
                return
            }
            // AppKit can reflect insets before their did-change notification, even for equal values.
            if !isReaderScrolling, !isHandlingReaderInput,
               insetChangeDepth > 0 || nativeGeometry() != laidOutNativeGeometry {
                requestLayout()
                return
            }
            if !isReaderScrolling { pendingReaderPages.removeAll() }
            readerScrolled()
        }

        private func readerScrolled() {
            guard hasLanded, let viewport else { return }
            cancelJumpAnimation(capturingPosition: false)
            let event: Model.Event = configuration?.holdsPosition == true || isReaderScrolling
                ? .holdCurrentPosition : .readerScrolled(to: nativeOrigin)
            intent = Model.reduce(intent, event, rows: frames,
                                  viewport: viewport, origin: nativeOrigin).intent
            if configuration?.holdsPosition != true, intent == .following {
                // Resolve newly exposed estimates before restoring the following threshold.
                intent = Model.reduce(intent, .holdCurrentPosition, rows: frames,
                                      viewport: viewport, origin: nativeOrigin).intent
                pendingResume = true
            }
            configuration?.onReaderScroll?(nativeOrigin + viewport.topInset < 32)
            requestLayout()
            publish()
        }

        private func publish() {
            guard let viewport else { return }
            let visibleSequence = readSequence(viewport: viewport)
            let snapshot = TranscriptDocumentState.Snapshot(
                hasLanded: hasLanded,
                isAtBottom: Model.distanceToEnd(nativeOrigin, rows: frames, viewport: viewport) <= Model.followingThreshold,
                visibleSequence: visibleSequence)
            state?.publish(snapshot)
        }

        private func readSequence(viewport: Model.Viewport) -> Int? {
            var sequences: [String: Int] = [:]
            var reads: [Model.RowFrame] = []
            for frame in frames {
                for (id, local) in messageFrames[frame.id] ?? [:] where local.sequence > 0 {
                    let read = Model.RowFrame(id: id, order: local.sequence, top: frame.top + local.contentTop,
                                              height: local.rect.height)
                    reads.append(read)
                    sequences[id] = local.sequence
                }
            }
            return Model.visibleRows(reads, viewport: viewport, origin: nativeOrigin).compactMap { sequences[$0] }.max()
        }

        func stopObserving() {
            cancelJumpAnimation(capturingPosition: false)
            notifications.forEach(NotificationCenter.default.removeObserver)
            notifications.removeAll()
            insetObservation = nil
            insetChangeDepth = 0
            state?.cancelPublication()
            observedBounds = nil
            laidOutNativeGeometry = nil
            isReaderScrolling = false
            pendingReaderPages.removeAll()
        }

        func layoutContent() {
            guard let scroll, let configuration, !isLayingOut else { return }
            let width = layoutWidth(proposed: scroll.contentSize.width)
            guard width > 0 else { return }
            isLayingOut = true
            defer {
                observedBounds = scroll.contentView.bounds
                laidOutNativeGeometry = nativeGeometry()
                isLayingOut = false
                if !invalidatedCells.isEmpty { requestLayout() }
                forwardPreparedReaderPage()
            }
            let updatesContent = isDirty || appliedWidth != width
            isDirty = false
            appliedWidth = width
            if ownsDocument {
                // Reloading a table during layout can leave AppKit's automatic insets one bar change behind.
                scroll.contentInsets = NSEdgeInsets(top: configuration.insets.top, left: 0,
                                                    bottom: configuration.insets.bottom, right: 0)
            }
            let result = measuredGeometry(items: configuration.items, content: configuration.content,
                                          header: configuration.header, footer: configuration.footer, width: width,
                                          environment: configuration.environment)
            let newFrames = rowFrames(items: configuration.items, heights: result.heights,
                                      hasFooter: configuration.footer != nil)
            let newViewport = currentViewport(width: width)
            let placement = proposedPlacement(rows: newFrames, viewport: newViewport)
            var oldHeights = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), heights))
            oldHeights.merge(appliedAccessoryHeights) { _, applied in applied }
            let oldIDs = tableIDs(items: items, hasFooter: footer != nil)
            let newIDs = tableIDs(items: configuration.items, hasFooter: configuration.footer != nil)
            let difference = newIDs.difference(from: oldIDs)
            var removed = IndexSet()
            var inserted = IndexSet()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            table.tableColumns[0].width = width
            table.setFrameSize(NSSize(width: width, height: table.frame.height))
            items = configuration.items
            content = configuration.content
            header = configuration.header
            footer = configuration.footer
            environment = configuration.environment
            heights = result.heights
            overflows = result.overflows
            documentHeight = Model.end(newFrames)
            frames = newFrames
            viewport = newViewport
            var needsNativeRowGeometry = !hasLoadedTable || !difference.isEmpty
            if !hasLoadedTable {
                table.reloadData()
                hasLoadedTable = true
            } else {
                var changedHeights = IndexSet()
                for row in newIDs.indices where oldHeights[newIDs[row]] != height(ofRow: row)
                    && !inserted.contains(row) {
                    changedHeights.insert(row)
                }
                needsNativeRowGeometry = needsNativeRowGeometry || !changedHeights.isEmpty
                if !difference.isEmpty || !changedHeights.isEmpty {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0
                        context.allowsImplicitAnimation = false
                        if !difference.isEmpty {
                            table.beginUpdates()
                            table.removeRows(at: removed, withAnimation: [])
                            table.insertRows(at: inserted, withAnimation: [])
                            table.endUpdates()
                        }
                        if !changedHeights.isEmpty { table.noteHeightOfRows(withIndexesChanged: changedHeights) }
                    }
                }
                if updatesContent || !changedHeights.isEmpty {
                    let range = table.rows(in: table.visibleRect)
                    if range.location != NSNotFound {
                        for row in range.location..<NSMaxRange(range) where row < table.numberOfRows {
                            if !updatesContent, !changedHeights.contains(row) { continue }
                            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCell {
                                configure(cell, row: row)
                            }
                        }
                    }
                }
            }
            appliedAccessoryHeights = [Self.headerID: headerHeight, Self.footerID: footerHeight]
            let retained = Set(items.map(\.id))
            messageFrames = messageFrames.filter { retained.contains($0.key) }
            table.layoutSubtreeIfNeeded()
            if needsNativeRowGeometry {
                // AppKit estimates unqueried delegate heights even with automatic sizing disabled.
                // Cache our cheap explicit heights, not additional SwiftUI measurements.
                for row in newIDs.indices { _ = table.rect(ofRow: row) }
            }
            table.setFrameSize(NSSize(width: width, height: documentHeight))
            if let placement {
                pendingEvents.removeAll()
                intent = placement.intent
                if let target = placement.unavailableTarget {
                    Task { @MainActor [weak state] in state?.reportUnavailable(target) }
                }
                if let origin = placement.origin {
                    let clip = scroll.contentView
                    let target = clip.convert(NSPoint(x: 0, y: origin), from: table).y
                    // A Jump must stop an existing AppKit page animation even at progress zero.
                    if stopsNativeScroll || abs(target - clip.bounds.minY) > 0.5 {
                        stopsNativeScroll = false
                        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
                    }
                }
                scroll.reflectScrolledClipView(scroll.contentView)
                hasLanded = true
            }
            if jumpAnimation?.progress == 1 {
                jumpAnimation?.stop()
                jumpAnimation = nil
            }
            if hasLanded, pendingResume, !isReaderScrolling, !configuration.holdsPosition, jumpAnimation == nil {
                intent = Model.reduce(intent, .resumeFromCurrentPosition, rows: frames,
                                      viewport: newViewport, origin: nativeOrigin).intent
                pendingResume = false
            }
            publish()
        }

        private func tableIDs(items: [TranscriptTableItem], hasFooter: Bool) -> [String] {
            [Self.headerID] + items.map(\.id) + (hasFooter ? [Self.footerID] : [])
        }

        private func height(ofRow row: Int) -> CGFloat {
            if row == 0 { return headerHeight }
            if row == items.count + 1 { return footerHeight }
            return heights[row - 1]
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count + 1 + (footer == nil ? 0 : 1) }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            height(ofRow: row)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = row == 0 ? Self.headerID : row == items.count + 1 ? Self.footerID : items[row - 1].id
            let cell = cell(for: id)
            configure(cell, row: row)
            return cell
        }

        private func cell(for id: String) -> TranscriptTableCell {
            // Reusing another row's cell rebuilds its SwiftUI graph on every return visit.
            let cell: TranscriptTableCell
            if let reused = cachedCells[id] {
                reusedCellCount += 1
                cell = reused
            } else {
                cell = TranscriptTableCell()
                cachedCells[id] = cell
            }
            recentCellIDs.removeAll { $0 == id }
            recentCellIDs.append(id)
            for old in recentCellIDs where cachedCells.count > Self.retainedCellLimit && old != id {
                guard let candidate = cachedCells[old] else { continue }
                if candidate.isDescendant(of: table), !candidate.visibleRect.isEmpty { continue }
                cachedCells[old] = nil
            }
            recentCellIDs.removeAll { cachedCells[$0] == nil }
            return cell
        }

        private func configure(_ cell: TranscriptTableCell, row: Int) {
            let view: AnyView
            cell.generation += 1
            if row == 0 {
                view = AnyView(header.padding(.top, 20))
                cell.representedID = nil
            } else if row == items.count + 1, let footer {
                view = AnyView(footer.modifier(ConversationRail()))
                cell.representedID = nil
            } else {
                let index = row - 1
                let id = items[index].id
                if cell.representedID != id || cell.measuredWidth != appliedWidth
                    || cell.measuredHeight != heights[index] {
                    messageFrames[id] = nil
                }
                cell.representedID = id
                cell.measuredWidth = appliedWidth
                cell.measuredEnvironment = TranscriptTableHeights.Environment(width: appliedWidth, values: environment)
                cell.measuredHeight = heights[index]
                let generation = cell.generation
                view = AnyView(content[index]
                    .equatable()
                    .environment(\.transcriptTableCoordinationOverflow, overflows[index])
                    .padding(.top, items[index].topSpacing)
                    .modifier(ConversationRail())
                    .id(id)
                    .coordinateSpace(name: "transcript-content")
                    .coordinateSpace(name: "transcript-viewport")
                    .transformPreference(TranscriptMessageFrames.self) { frames in
                        frames = frames.mapValues { frame in
                            var frame = frame
                            frame.layoutGeneration = generation
                            return frame
                        }
                    }
                    .onPreferenceChange(TranscriptMessageFrames.self) { [weak self, weak cell] frames in
                        guard let self, cell?.representedID == id, cell?.generation == generation,
                              frames.values.allSatisfy({ $0.layoutGeneration == generation }) else { return }
                        self.messageFrames[id] = frames
                        self.publish()
                    })
            }
            cell.host.rootView = AnyView(view
                .frame(width: appliedWidth, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.self, environment))
            cell.host.onHeightInvalidated = { [weak self, weak cell] in
                guard let self, let id = cell?.representedID else { return }
                self.invalidatedCells.insert(id)
                if !self.isLayingOut && !self.isRefiningHeights { self.requestLayout() }
            }
        }
    }
}

final class TranscriptTableScrollView: NSScrollView {
    weak var coordinator: TranscriptTablePrototype.Coordinator?

    override func layout() {
        super.layout()
        coordinator?.layoutContent()
    }
}

final class TranscriptTableView: NSTableView {
    weak var coordinator: TranscriptTablePrototype.Coordinator?

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let coordinator else {
            super.keyDown(with: event)
            return
        }
        if event.specialKey == .pageUp {
            scrollPageUp(self)
            return
        }
        if event.specialKey == .pageDown {
            scrollPageDown(self)
            return
        }
        coordinator.performReaderInput { routeKeyDown(with: event) }
    }

    private func routeKeyDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView else {
            super.keyDown(with: event)
            return
        }
        switch event.specialKey {
        case .upArrow, .downArrow:
            let direction: CGFloat = event.specialKey == .upArrow ? -1 : 1
            let flipped: CGFloat = scroll.documentView?.isFlipped == false ? -1 : 1
            let clip = scroll.contentView
            let proposed = clip.bounds.offsetBy(dx: 0, dy: direction * flipped * scroll.verticalLineScroll)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(clip)
        default:
            super.keyDown(with: event)
        }
    }

    override func scrollPageUp(_ sender: Any?) {
        if let coordinator { coordinator.prepareReaderPage(towardOlder: true) }
        else { super.scrollPageUp(sender) }
    }

    override func scrollPageDown(_ sender: Any?) {
        if let coordinator { coordinator.prepareReaderPage(towardOlder: false) }
        else { super.scrollPageDown(sender) }
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let view = responder as? NSView, view.isDescendant(of: self) { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

private final class TranscriptTableCell: NSTableCellView {
    let host = TranscriptTableHostingView(rootView: AnyView(EmptyView()))
    var representedID: String?
    var measuredWidth: CGFloat = 0
    var measuredEnvironment: TranscriptTableHeights.Environment?
    var measuredHeight: CGFloat = 0
    var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        addSubview(host)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("Transcript cells are created programmatically.") }

    override func layout() {
        super.layout()
        host.frame = bounds
    }
}

final class TranscriptTableHostingView: NSHostingView<AnyView> {
    var onHeightInvalidated: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onHeightInvalidated?()
    }
}

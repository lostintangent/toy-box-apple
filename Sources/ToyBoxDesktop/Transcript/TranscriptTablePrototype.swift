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

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private struct Configuration {
            let items: [TranscriptTableItem]
            let content: [TranscriptRowContent]
            let header: AnyView
            let environment: EnvironmentValues
            let insets: EdgeInsets
        }

        let table = TranscriptTableView()
        private weak var scroll: TranscriptTableScrollView?
        private let cache = TranscriptTableHeights()
        private var items: [TranscriptTableItem] = []
        private var content: [TranscriptRowContent] = []
        private var header = AnyView(EmptyView())
        private var environment = EnvironmentValues()
        private var heights: [CGFloat] = []
        private var overflows: [Bool?] = []
        private var headerHeight: CGFloat = 20
        private var appliedWidth: CGFloat = 0
        private var isDirty = false
        private var isLayingOut = false
        private var hasLanded = false
        private var configuration: Configuration?

        func attach(_ scroll: TranscriptTableScrollView) {
            self.scroll = scroll
            scroll.coordinator = self
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
            scroll.documentView = table
        }

        func update(items: [TranscriptTableItem], content: [TranscriptRowContent], header: AnyView,
                    environment: EnvironmentValues, insets: EdgeInsets) {
            configuration = Configuration(items: items, content: content, header: header,
                                          environment: environment, insets: insets)
            isDirty = true
            scroll?.needsLayout = true
        }

        func layoutContent() {
            guard let scroll, let configuration, !isLayingOut else { return }
            let width = scroll.contentSize.width
            guard width > 0, isDirty || appliedWidth != width else { return }
            isLayingOut = true
            defer { isLayingOut = false }
            isDirty = false
            appliedWidth = width
            // Reloading a table during layout can leave AppKit's automatic insets one bar change behind.
            scroll.contentInsets = NSEdgeInsets(top: configuration.insets.top, left: 0,
                                                bottom: configuration.insets.bottom, right: 0)
            let result = cache.resolve(items: configuration.items, content: configuration.content, width: width,
                                       environment: configuration.environment)
            let headerHeight = 20 + cache.measureAccessory(configuration.header, width: width,
                                                           environment: configuration.environment)
            table.tableColumns[0].width = width
            table.setFrameSize(NSSize(width: width, height: table.frame.height))
            items = configuration.items
            content = configuration.content
            header = configuration.header
            environment = configuration.environment
            heights = result.heights
            overflows = result.overflows
            self.headerHeight = headerHeight
            table.reloadData()
            table.layoutSubtreeIfNeeded()
            if !hasLanded, !items.isEmpty {
                let target = items.firstIndex { $0.row.divider?.unread == true }
                let origin = target.map { table.rect(ofRow: $0 + 1).minY - scroll.contentInsets.top }
                    ?? max(-scroll.contentInsets.top,
                           table.frame.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: origin))
                scroll.reflectScrolledClipView(scroll.contentView)
                hasLanded = true
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count + 2 }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if row == 0 { return headerHeight }
            if row == items.count + 1 { return 16 }
            return heights[row - 1]
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == items.count + 1 { return nil }
            let identifier = NSUserInterfaceItemIdentifier("transcript-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TranscriptTableCell
                ?? TranscriptTableCell()
            cell.identifier = identifier
            let view: AnyView
            if row == 0 {
                view = AnyView(header.padding(.top, 20))
            } else {
                let index = row - 1
                view = AnyView(content[index]
                    .environment(\.transcriptTableCoordinationOverflow, overflows[index])
                    .padding(.top, items[index].topSpacing)
                    .modifier(ConversationRail())
                    .id(items[index].id))
            }
            cell.host.rootView = AnyView(view
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.self, environment))
            return cell
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
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let view = responder as? NSView, view.isDescendant(of: self) { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

private final class TranscriptTableCell: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = []
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

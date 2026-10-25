import AppKit
import SwiftUI

struct TranscriptDocumentPrototype: NSViewRepresentable {
    static let isEnabled = ProcessInfo.processInfo.environment["TOY_BOX_TRANSCRIPT"] == "document"

    let items: [TranscriptTableItem]
    let content: [TranscriptRowContent]
    let header: AnyView

    func makeCoordinator() -> TranscriptTablePrototype.Coordinator { .init() }

    func makeNSView(context: Context) -> TranscriptTableDocument {
        TranscriptTableDocument(coordinator: context.coordinator)
    }

    func updateNSView(_ view: TranscriptTableDocument, context: Context) {
        context.coordinator.update(items: items, content: content, header: header,
                                   environment: context.environment, insets: EdgeInsets())
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptTableDocument,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let height = context.coordinator.fittingHeight(items: items, content: content, header: header,
                                                       width: width, environment: context.environment)
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: TranscriptTableDocument,
                               coordinator: TranscriptTablePrototype.Coordinator) {
        view.stopEdgeTrace()
    }
}

final class TranscriptTableDocument: NSView {
    let coordinator: TranscriptTablePrototype.Coordinator
    private weak var scroll: NSScrollView?
    private var edgeTrace: TranscriptEdgeTrace?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: coordinator.documentHeight)
    }

    init(coordinator: TranscriptTablePrototype.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        addSubview(coordinator.table)
    }

    required init?(coder: NSCoder) { fatalError("Transcript documents are created programmatically.") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopEdgeTrace()
        guard let enclosing = enclosingScrollView else { return }
        scroll = enclosing
        coordinator.attach(enclosing, ownsDocument: false)
        needsLayout = true
        if TranscriptEdgeTrace.mode != nil {
            let trace = TranscriptEdgeTrace(view: self, scroll: enclosing)
            edgeTrace = trace
            trace.start()
        }
    }

    override func layout() {
        super.layout()
        coordinator.table.frame = bounds
        let oldHeight = coordinator.documentHeight
        coordinator.layoutContent()
        if coordinator.documentHeight != oldHeight { invalidateIntrinsicContentSize() }
    }

    func stopEdgeTrace() {
        edgeTrace?.stop()
        edgeTrace = nil
    }
}

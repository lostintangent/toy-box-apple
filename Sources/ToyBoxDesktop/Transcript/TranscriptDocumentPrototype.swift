import AppKit
import SwiftUI

struct TranscriptDocumentPrototype: NSViewRepresentable {
    static let isEnabled = ProcessInfo.processInfo.environment["TOY_BOX_TRANSCRIPT"] == "document"

    let items: [TranscriptTableItem]
    let content: [TranscriptRowContent]
    let header: AnyView
    var footer: AnyView? = nil
    var state: TranscriptDocumentState? = nil
    var windowObserver: TranscriptWindowObserver? = nil
    var isReadyToLand = true
    var command: TranscriptDocumentState.Command? = nil
    // Reading the phase in the parent makes summary changes invalidate native sizing.
    var sizingPhase: TranscriptCatchUp.Phase? = nil
    var holdsPosition = false
    var onDraw: ((TranscriptTableDocument) -> Void)? = nil

    func makeCoordinator() -> TranscriptTablePrototype.Coordinator { .init() }

    func makeNSView(context: Context) -> TranscriptTableDocument {
        let view = TranscriptTableDocument(coordinator: context.coordinator)
        view.windowObserver = windowObserver
        view.onDraw = onDraw
        return view
    }

    func updateNSView(_ view: TranscriptTableDocument, context: Context) {
        context.coordinator.update(items: items, content: content, header: header,
                                   environment: context.environment, insets: EdgeInsets(), state: state,
                                   isReadyToLand: isReadyToLand, footer: footer, holdsPosition: holdsPosition)
        context.coordinator.accept(command)
        view.windowObserver = windowObserver
        view.onDraw = onDraw
        windowObserver?.attach(to: view, observesResizes: false)
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptTableDocument,
                      context: Context) -> CGSize? {
        // SwiftUI's proposal already excludes its safe-area padding, including the sidebar.
        if proposal.width == 0 { return .zero }
        let width = proposal.width ?? context.coordinator.layoutWidth(
            proposed: nsView.enclosingScrollView?.contentSize.width ?? nsView.bounds.width)
        guard width > 0, width.isFinite else { return nil }
        let height = context.coordinator.fittingHeight(items: items, content: content, header: header,
                                                       width: width, environment: context.environment, footer: footer)
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: TranscriptTableDocument,
                               coordinator: TranscriptTablePrototype.Coordinator) {
        view.stopEdgeTrace()
        coordinator.stopObserving()
        view.windowObserver?.detach()
    }
}

final class TranscriptTableDocument: NSView {
    let coordinator: TranscriptTablePrototype.Coordinator
    private var edgeTrace: TranscriptEdgeTrace?
    weak var windowObserver: TranscriptWindowObserver?
    var onDraw: ((TranscriptTableDocument) -> Void)?

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
        guard window != nil, let enclosing = enclosingScrollView else {
            coordinator.stopObserving()
            windowObserver?.detach()
            return
        }
        coordinator.attach(enclosing, ownsDocument: false, document: self)
        windowObserver?.attach(to: self, observesResizes: false)
        invalidateIntrinsicContentSize()
        needsLayout = true
        if TranscriptEdgeTrace.mode == "record" || TranscriptEdgeTrace.mode == "step" {
            let trace = TranscriptEdgeTrace(view: self, scroll: enclosing)
            edgeTrace = trace
            trace.start()
        }
    }

    override func layout() {
        super.layout()
        let width = coordinator.layoutWidth(proposed: enclosingScrollView?.contentSize.width ?? bounds.width)
        coordinator.table.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let oldHeight = coordinator.documentHeight
        coordinator.layoutContent()
        if coordinator.documentHeight != oldHeight { invalidateIntrinsicContentSize() }
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        onDraw?(self)
    }

    func stopEdgeTrace() {
        edgeTrace?.stop()
        edgeTrace = nil
    }
}

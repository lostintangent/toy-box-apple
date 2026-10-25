import AppKit

@MainActor
final class TranscriptTableEdges: NSSplitViewController {
    let contentController: NSViewController
    let contentItem: NSSplitViewItem
    let topEdge = NSSplitViewItemAccessoryViewController()
    let bottomEdge = NSSplitViewItemAccessoryViewController()
    private let topHeight: NSLayoutConstraint
    private let bottomHeight: NSLayoutConstraint
    private var topInset: CGFloat = 0
    private var bottomInset: CGFloat = 0

    init(content: NSView) {
        let controller = NSViewController()
        controller.view = content
        contentController = controller
        contentItem = NSSplitViewItem(viewController: controller)
        let top = NSView()
        let bottom = NSView()
        topHeight = top.heightAnchor.constraint(equalToConstant: 0)
        bottomHeight = bottom.heightAnchor.constraint(equalToConstant: 0)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        contentItem.automaticallyAdjustsSafeAreaInsets = true
        addSplitViewItem(contentItem)
        topEdge.view = top
        bottomEdge.view = bottom
        topEdge.automaticallyAppliesContentInsets = false
        bottomEdge.automaticallyAppliesContentInsets = false
        topEdge.preferredScrollEdgeEffectStyle = .hard
        bottomEdge.preferredScrollEdgeEffectStyle = .soft
        topHeight.isActive = true
        bottomHeight.isActive = true
        contentItem.addTopAlignedAccessoryViewController(topEdge)
        contentItem.addBottomAlignedAccessoryViewController(bottomEdge)
    }

    required init?(coder: NSCoder) {
        fatalError("Transcript edge controllers are created programmatically.")
    }

    func update(top: CGFloat, bottom: CGFloat) {
        precondition(top.isFinite && bottom.isFinite && top >= 0 && bottom >= 0)
        topInset = top
        bottomInset = bottom
        updateHeights()
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        updateHeights()
    }

    private func updateHeights() {
        // The window already contributes its own title and toolbar region.
        let top = max(0, topInset - view.safeAreaInsets.top)
        let bottom = max(0, bottomInset - view.safeAreaInsets.bottom)
        if topHeight.constant != top { topHeight.constant = top }
        if bottomHeight.constant != bottom { bottomHeight.constant = bottom }
    }
}

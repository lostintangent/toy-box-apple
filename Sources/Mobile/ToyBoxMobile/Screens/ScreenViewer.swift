import ChannelClient
import SwiftUI
import ToyBoxUI
import UIKit

/// A screen over the whole app, pinch-zoomable to 4× and live while the app is active. A settled
/// zoom asks for sharper frames, and a screen that stops being live zooms out to show its status.
struct ScreenViewer: View {
    @ViewState private var connection: ScreenConnection
    @ViewState private var zoom: CGFloat = 1
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(api: ChannelAPI, screenID: String) {
        _connection = ViewState(wrappedValue: ScreenConnection(api: api, screenID: screenID))
    }

    var body: some View {
        NavigationStack {
            Zooming(zoom: $zoom, content: ScreenView(connection: connection, zoom: zoom,
                                                     isActive: scenePhase == .active))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(connection.state.title ?? "Screen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                            .accessibilityLabel("Close Screen")
                    }
                }
        }
        .onChange(of: connection.state.phase) { _, phase in
            if phase != .live { zoom = 1 }
        }
    }

    /// Hosts the screen in a scroll view that pinches and pans it. Its layout size stays the
    /// viewer's, so the zoom reaches the screen only as the settled scale.
    private struct Zooming: UIViewRepresentable {
        @Binding var zoom: CGFloat
        let content: ScreenView

        func makeUIView(context: Context) -> Canvas { Canvas(content: content) }

        func updateUIView(_ canvas: Canvas, context: Context) {
            canvas.host.rootView = content
            canvas.settle = { zoom = $0 }
            if zoom != canvas.settled {
                canvas.settled = zoom
                canvas.setZoomScale(zoom, animated: true)
            }
        }

        final class Canvas: UIScrollView, UIScrollViewDelegate {
            let host: UIHostingController<ScreenView>
            /// The latest pinch's settled scale, so new frames don't pull back a pinch under way.
            var settled: CGFloat = 1
            var settle: (CGFloat) -> Void = { _ in }

            init(content: ScreenView) {
                host = UIHostingController(rootView: content)
                super.init(frame: .zero)
                // A panned screen would otherwise move its content away from the safe area.
                host.safeAreaRegions = []
                host.view.backgroundColor = .clear
                delegate = self
                maximumZoomScale = 4
                showsHorizontalScrollIndicator = false
                showsVerticalScrollIndicator = false
                addSubview(host.view)
            }

            required init?(coder: NSCoder) { nil }

            override func layoutSubviews() {
                super.layoutSubviews()
                // A rotated viewer fits the screen again.
                guard host.view.bounds.size != bounds.size else { return }
                zoomScale = 1
                host.view.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
                guard settled != 1 else { return }
                settled = 1
                // Outside the layout pass, which can run inside a SwiftUI update.
                DispatchQueue.main.async { [settle] in settle(1) }
            }

            func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }

            func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
                settled = scale
                settle(scale)
            }
        }
    }
}

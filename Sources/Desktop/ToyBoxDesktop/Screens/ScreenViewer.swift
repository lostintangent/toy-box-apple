import AppKit
import ChannelClient
import SwiftUI
import ToyBoxUI

/// One screen in a Screens window, live while any of the window shows. Going back, or a
/// miniaturized, hidden or fully covered window, closes its socket, so the host stops capturing for it.
struct ScreenViewer: View {
    @ViewState private var connection: ScreenConnection
    @ViewState private var isVisible = false

    init(api: ChannelAPI, screenID: String) {
        _connection = ViewState(wrappedValue: ScreenConnection(api: api, screenID: screenID))
    }

    var body: some View {
        ScreenView(connection: connection, isActive: isVisible)
            .navigationTitle(connection.state.title ?? "Screen")
            .background(Occlusion(isVisible: $isVisible))
    }

    private struct Occlusion: NSViewRepresentable {
        @Binding var isVisible: Bool

        func makeNSView(context: Context) -> Observer { Observer() }
        func updateNSView(_ view: Observer, context: Context) { view.report = { isVisible = $0 } }

        final class Observer: NSView {
            var report: (Bool) -> Void = { _ in }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                NotificationCenter.default.removeObserver(self)
                guard let window else { return }
                NotificationCenter.default.addObserver(self, selector: #selector(reportVisibility),
                                                       name: NSWindow.didChangeOcclusionStateNotification,
                                                       object: window)
                // Outside the SwiftUI update that moved the view.
                DispatchQueue.main.async { [weak self] in self?.reportVisibility() }
            }

            @objc private func reportVisibility() { report(window?.occlusionState.contains(.visible) == true) }
        }
    }
}

import ChannelClient
import ChannelKit
import SwiftUI

/// A screen fitted to its space, live while the view is active. The host captures only the pixels
/// it can show.
public struct ScreenView: View {
    private let connection: ScreenConnection
    private let isActive: Bool
    @Environment(\.displayScale) private var displayScale
    @ViewState private var space = CGSize.zero

    public init(connection: ScreenConnection, isActive: Bool = true) {
        self.connection = connection
        self.isActive = isActive
    }

    public var body: some View {
        // The picture is empty until the first frame, so the view's lifetime hangs off its space.
        Color.clear
            .overlay { Picture(connection: connection, space: space) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { space = $0 }
            .task(id: pixels) { connection.viewerSize = pixels }
            .onDisappear { connection.viewerSize = nil }
            .overlay { Status(connection: connection) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Screen: \(connection.state.title ?? connection.screenID)")
    }

    /// The pixels the view can show while it's active, or nil while it can't show any.
    private var pixels: CGSize? {
        guard isActive, space.width * displayScale >= 1, space.height * displayScale >= 1 else { return nil }
        return CGSize(width: space.width * displayScale, height: space.height * displayScale)
    }

    /// The latest full frame with its changed region over it, clipped to a window's corners, and ringed
    /// in the accent color while this viewer controls the host.
    private struct Picture: View {
        let connection: ScreenConnection
        let space: CGSize

        var body: some View {
            let picture = connection.picture
            if let image = picture.image, picture.size.width > 0, picture.size.height > 0 {
                let scale = min(space.width / picture.size.width, space.height / picture.size.height)
                let shape = RoundedRectangle(cornerRadius: picture.radius * scale, style: .continuous)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable()
                    if let region = picture.region {
                        Image(decorative: region.image, scale: 1).resizable()
                            .frame(width: CGFloat(region.bounds.width) * scale,
                                   height: CGFloat(region.bounds.height) * scale)
                            .offset(x: CGFloat(region.bounds.x) * scale, y: CGFloat(region.bounds.y) * scale)
                    }
                }
                .frame(width: picture.size.width * scale, height: picture.size.height * scale)
                .clipShape(shape)
                .overlay {
                    if connection.state.hasControl { shape.strokeBorder(.tint, lineWidth: 2) }
                }
            }
        }
    }

    /// The viewer's Take Control toggle, enabled while the screen is live. It follows the server, so
    /// it turns off when anyone else takes control, and in control it's prominent, like the picture's
    /// accent ring.
    public struct ControlToggle: View {
        private let connection: ScreenConnection

        public init(connection: ScreenConnection) {
            self.connection = connection
        }

        public var body: some View {
            let hasControl = connection.state.hasControl
            let title = hasControl ? "Release Control" : "Take Control"
            let button = Button(title, systemImage: hasControl ? "hand.point.up.left.fill" : "hand.point.up.left") {
                if hasControl { connection.releaseControl() } else { connection.takeControl() }
            }
            .help(title)
            .disabled(connection.state.phase != .live)
            if hasControl { button.buttonStyle(.glassProminent) } else { button }
        }
    }

    /// What the view shows until its screen is live, or once it no longer is. The iPhone viewer lays
    /// it over its own zooming canvas.
    public struct Status: View {
        private let connection: ScreenConnection

        public init(connection: ScreenConnection) {
            self.connection = connection
        }

        public var body: some View {
            let state = connection.state
            let title = state.title ?? "screen"
            Group {
                switch state.phase {
                case .live: EmptyView()
                case .connecting:
                    DelayedProgressView("Connecting to \(title)…")
                case .paused:
                    ContentUnavailableView("Screen paused", systemImage: "pause.rectangle",
                                           description: Text(state.reason ?? "The host has suspended capture."))
                case .ended:
                    ContentUnavailableView {
                        Label("Unable to show \(title)", systemImage: "rectangle.slash")
                    } description: {
                        Text(state.reason ?? "This screen is no longer available.")
                    } actions: {
                        Button("Try Again", action: connection.retry)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(state.phase == .paused ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear))
        }
    }
}

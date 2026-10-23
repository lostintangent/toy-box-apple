import ChannelClient
import SwiftUI

/// The catalog connection as the sidebar footer reports it. An open channel's own stream reports
/// its state in the detail column instead.
enum SidebarConnection: Equatable {
    case connecting, connected, reconnecting, unreachable

    /// `fatal` covers failures a retry can't fix, such as an invalid URL or a refused authorization,
    /// so they read as unreachable even while earlier rows stay listed.
    init(loaded: Bool, failing: Bool, fatal: Bool) {
        if fatal || (failing && !loaded) { self = .unreachable }
        else if failing { self = .reconnecting }
        else { self = loaded ? .connected : .connecting }
    }

    static func isFatal(_ failure: (any Error)?) -> Bool {
        guard case .http(let status, _)? = failure as? ChannelAPIError else { return false }
        return status == 401 || status == 403
    }

    var dot: Color {
        switch self {
        case .connecting: .secondary
        case .connected: .green
        case .reconnecting: .orange
        case .unreachable: .red
        }
    }

    var heading: String? {
        switch self {
        case .connecting, .connected: nil
        case .reconnecting: "Channels may be out of date"
        case .unreachable: "Can't connect to Toy Box"
        }
    }

    var verb: String {
        switch self {
        case .connecting: "Connecting to"
        case .connected: "Connected to"
        case .reconnecting: "Reconnecting to"
        case .unreachable: "Can't connect to"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .unreachable: "can't connect"
        }
    }

    /// Host and port, without the port when it is the scheme's default. Anything that isn't a URL
    /// with a host shows as typed, so a bad setting is still recognizable.
    static func server(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
            return url
        }
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port = components.port else { return name }
        let standard = ["http": 80, "https": 443][components.scheme?.lowercased() ?? ""]
        return port == standard ? name : "\(name):\(port)"
    }
}

/// The bottom of the sidebar: the error block when there is one, then a status dot and the server,
/// which opens Settings. It has no background of its own, so rows scroll beneath it under the
/// system scroll edge effect. It is also the sidebar's only progress indicator.
struct SidebarConnectionFooter: View {
    let connection: SidebarConnection
    /// The first load or a Retry the person pressed is in flight. Background polling never is.
    let busy: Bool
    let serverURL: String
    let error: String?
    let retry: (() -> Void)?
    let openSettings: () -> Void
    /// An attempt that resolves sooner than this never shows the spinner.
    var spinnerDelay: Duration = .milliseconds(300)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var showsSpinner = false

    /// The channel icons' leading edge in the sidebar, which the dot and block share.
    static let leading: CGFloat = 24
    /// The status line's capsule reaches this far past the dot on each side.
    static let capsuleOutset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let heading = connection.heading, let error {
                errorBlock(heading: heading, error: error)
                    .padding(.horizontal, Self.leading)
            }
            Button(action: openSettings) {
                SidebarStatusLine(connection: connection, spinning: showsSpinner, serverURL: serverURL)
            }
            .buttonStyle(TokenCapsuleButtonStyle(emphasized: false))
            .help("\(connection.verb) \(serverURL)\nChange the server in Settings.")
            .accessibilityLabel("Server")
            .accessibilityValue("\(SidebarConnection.server(serverURL)), \(connection.accessibilityValue)")
            .padding(.horizontal, Self.leading - Self.capsuleOutset)
        }
        .padding(.top, 6)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: busy) {
            if busy {
                do { try await Task.sleep(for: spinnerDelay) } catch { return }
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsSpinner = busy }
        }
    }

    private func errorBlock(heading: String, error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(heading, systemImage: "wifi.exclamationmark")
                .font(.caption.weight(.medium))
            Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                if let retry { Button("Retry", action: retry) }
                Button("Settings", action: openSettings)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The dot, or a spinner in its slot, then the server. The 10-point mini spinner centers on the
/// 7-point dot and overhangs it unclipped, so the host never moves.
struct SidebarStatusLine: View {
    let connection: SidebarConnection
    let spinning: Bool
    let serverURL: String
    @Environment(\.channelTextScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(connection.dot)
                .frame(width: 7, height: 7)
                .opacity(spinning ? 0 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: connection)
                .overlay {
                    if spinning {
                        ProgressView().controlSize(.mini).fixedSize().transition(.opacity)
                    }
                }
            Text(SidebarConnection.server(serverURL))
                .font(.system(size: 11 * scale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, SidebarConnectionFooter.capsuleOutset)
        .frame(height: 22 * scale)
        .contentShape(Capsule())
    }
}

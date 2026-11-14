import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// Welcome's Server URL card: the address, and why the last Connect failed under it.
struct ServerConnectionSection: View {
    @Binding var address: String
    let failure: (any Error)?
    let connect: () -> Void

    var body: some View {
        Section {
            TextField("Server URL", text: $address, prompt: Text("machine.tail1234.ts.net"))
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .accessibilityIdentifier("server-address")
                .onSubmit(connect)
            if let failure {
                if failure as? ChannelAPIError == .invalidServerURL {
                    ServerErrorLabel(message: Self.validationMessage(address))
                } else {
                    ServerErrorLabel(message: Self.failureMessage(failure), help: Self.failureHelp)
                }
            }
        } header: {
            Text("Server URL")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use your server's address, including its port and any path prefix. If it runs on another computer, this iPhone needs to reach it, for example over Tailscale.")
                if let host = loopbackHost {
                    Text("“\(host)” points to this iPhone. Use an address this iPhone can reach, like your server's Tailscale name.")
                }
            }
        }
    }

    static let failureHelp = "Check the address, and that your Toy Box server is running and reachable from this iPhone."

    private var loopbackHost: String? {
        guard let url = try? ChannelAPI(serverURL: address).baseURL, let host = url.host,
              ChannelAPI.isLoopback(host: host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))) else {
            return nil
        }
        return host
    }

    /// What's wrong with an address the app can't use.
    static func validationMessage(_ address: String) -> String {
        let fallback = ChannelAPIError.invalidServerURL.localizedDescription
        guard let parts = URLComponents(serverAddress: address) else { return fallback }
        guard ["http", "https"].contains(parts.scheme?.lowercased()) else { return "Use HTTP or HTTPS for your Toy Box server." }
        guard let host = parts.host, !host.isEmpty else { return "Include your server's hostname or IP address." }
        if parts.user != nil || parts.password != nil { return "Remove usernames and passwords from the server URL." }
        if parts.query != nil || parts.fragment != nil { return "Use the server's base URL without a query or fragment." }
        return fallback
    }

    static func failureMessage(_ error: any Error) -> String {
        if case .keyNotFound(let key, _) = error as? DecodingError, key.stringValue == "lead" {
            return "Protocol error: the server catalog is missing its required Lead profile."
        }
        if error is DecodingError { return "Protocol error: \(error.localizedDescription)" }
        if let error = error as? ChannelAPIError {
            switch error {
            case .http(let status, _) where status == 401 || status == 403:
                return "Authorization error: \(error.localizedDescription)"
            case .invalidResponse, .invalidEvent:
                return "Protocol error: \(error.localizedDescription)"
            default:
                return error.localizedDescription
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return "TLS connection error: \(error.localizedDescription)"
            default:
                break
            }
        }
        return "Connection error: \(error.localizedDescription)"
    }
}

/// A saved server's address, which can be copied but not edited, with a checkmark while it's
/// connected or why it can't connect under it.
struct ServerAddressSection: View {
    let catalog: ChannelCatalogStore

    var body: some View {
        Section("Server URL") {
            HStack {
                // Secondary, so a value that can't change reads apart from a filled field.
                Text(catalog.api.baseURL.absoluteString).foregroundStyle(.secondary).textSelection(.enabled)
                if catalog.phase == .connected {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(catalog.phase == .connected ? "Connected" : "")
            if let error = catalog.phase.failure {
                ServerErrorLabel(message: ServerConnectionSection.failureMessage(error),
                                 help: ServerConnectionSection.failureHelp)
            }
        }
    }
}

/// An error in a Server URL card, after a red circle on its first line, with what to check under it.
private struct ServerErrorLabel: View {
    let message: String
    var help: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                if let help { Text(help).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
        .labelStyle(ErrorLabelStyle())
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

/// The icon sits on the error's first line, and the help below lines up with the error text.
private struct ErrorLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}

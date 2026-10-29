import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The Server URL card shared by Welcome and Settings: the address, Test Connection and its errors.
struct ServerConnectionSection: View {
    let connection: ServerConnectionProbe
    let placeholder: String
    let footer: String
    /// The server in use, which a failed test names because the field now shows another one.
    var currentServer: String?
    /// Settings applies a successful test, and the row reads Connecting… until the switch lands.
    var isSwitching = false
    @Binding var failure: String?

    var body: some View {
        @Bindable var connection = connection
        Section {
            TextField("Server URL", text: $connection.address, prompt: Text(placeholder))
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .accessibilityIdentifier("server-address")
                .onSubmit {
                    if canTest { test() }
                }
            Button(action: test) {
                HStack {
                    Text(isBusy ? "Connecting…" : testTitle)
                    if isBusy { ProgressView() }
                    if isConnected {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityValue(isConnected ? "Connected" : "")
            .accessibilityIdentifier("server-test")
            .disabled(!canTest)
            if let message = Self.validationMessage(address: connection.address, error: connection.validationError) {
                errorLabel(message)
            }
            if case .failed(let address, let error)? = connection.phase {
                errorLabel(Self.failureMessage(error), help: failureHelp(testing: address))
            }
            if let failure { errorLabel(failure) }
        } header: {
            Text("Server URL")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(footer)
                if let host = loopbackHost {
                    Text("“\(host)” points to this iPhone. Use an address this iPhone can reach, like your server's Tailscale name.")
                }
            }
        }
        .onChange(of: connection.address) { _, _ in failure = nil }
    }

    var canTest: Bool { !connection.isConnecting && !isSwitching && connection.validationError == nil }

    /// The address in the field connected. Editing it clears the probe, and with it this checkmark.
    var isConnected: Bool {
        guard !isBusy, case .connected? = connection.phase else { return false }
        return true
    }

    private var isBusy: Bool { connection.isConnecting || isSwitching }

    private func failureHelp(testing address: String) -> String {
        let help = "Check the address, and that your Toy Box server is running and reachable from this iPhone."
        guard let currentServer, let current = ChannelWaitingRequest.normalizedServer(currentServer),
              current != ChannelWaitingRequest.normalizedServer(address) else { return help }
        return "\(help) Still using \(SidebarFooter.server(currentServer))."
    }

    private var loopbackHost: String? {
        guard let url = try? ChannelAPI(serverURL: connection.address).baseURL, let host = url.host,
              isLoopbackHost(host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))) else {
            return nil
        }
        return host
    }

    private var testTitle: String {
        if case .failed? = connection.phase { return "Retry" }
        return "Test Connection"
    }

    private func test() {
        failure = nil
        connection.start()
    }

    private func errorLabel(_ message: String, help: String? = nil) -> some View {
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
    static func validationMessage(address: String, error: String?) -> String? {
        guard let error, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return error
        }
        guard let scheme = parts.scheme else { return "Enter the full server URL, starting with http:// or https://." }
        guard ["http", "https"].contains(scheme.lowercased()) else { return "Use HTTP or HTTPS for your Toy Box server." }
        guard let host = parts.host, !host.isEmpty else { return "Include your server's hostname or IP address." }
        if parts.user != nil || parts.password != nil { return "Remove usernames and passwords from the server URL." }
        if parts.query != nil || parts.fragment != nil { return "Use the server's base URL without a query or fragment." }
        return error
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
            case .invalidResponse, .unsupportedVersion, .invalidEvent:
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

/// The icon sits on the error's first line, and the help below lines up with the error text.
private struct ErrorLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}

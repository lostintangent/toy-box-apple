import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ServerConnectionSection: View {
    let connection: ServerConnectionProbe
    let requiresTest: Bool
    let currentServer: String?
    let onUse: () -> Void
    @Binding var useFailure: String?

    var body: some View {
        @Bindable var connection = connection
        Section {
            TextField("Server URL", text: $connection.address, prompt: Text("Required"))
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
                    Text(connection.isConnecting ? "Connecting…" : testTitle)
                    if connection.isConnecting { ProgressView() }
                }
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("server-test")
            .disabled(!canTest)
            Button(requiresTest ? "Continue" : "Use Server", action: onUse)
                .frame(minHeight: 44)
                .accessibilityIdentifier("server-use")
                .disabled(!canUse)
            if let message = Self.validationMessage(address: connection.address, error: connection.validationError) {
                errorLabel(message)
            }
            switch connection.phase {
            case .connected(let url, _)?:
                Label("Connected to \(SidebarFooter.server(url.absoluteString))", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .failed(let address, let error)?:
                VStack(alignment: .leading, spacing: 4) {
                    errorLabel(Self.failureMessage(error))
                    Text(address).font(.footnote).textSelection(.enabled)
                    Text("Check Tailscale, your Mac's server address, and that your Mac is awake with Toy Box running.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .connecting?, nil:
                EmptyView()
            }
            if let useFailure { errorLabel(useFailure) }
        } header: {
            Text("Server")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use an HTTP or HTTPS URL, including any server path prefix.")
                if let host = loopbackHost {
                    Text("\(host) points to this iPhone, not your Mac. To reach your Mac, use its Tailscale address.")
                }
            }
        }
        .onChange(of: connection.address) { _, _ in useFailure = nil }
    }

    var canTest: Bool { !connection.isConnecting && connection.validationError == nil }

    var canUse: Bool {
        guard canTest else { return false }
        if requiresTest {
            guard case .connected? = connection.phase else { return false }
        }
        if let currentServer,
           ChannelWaitingRequest.normalizedServer(currentServer)
            == ChannelWaitingRequest.normalizedServer(connection.address) { return false }
        return true
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
        useFailure = nil
        connection.start()
    }

    private func errorLabel(_ message: String) -> some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
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
        guard let host = parts.host, !host.isEmpty else { return "Include your Mac's hostname or Tailscale IP address." }
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

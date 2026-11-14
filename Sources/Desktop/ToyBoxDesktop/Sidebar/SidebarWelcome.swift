import ChannelClient
import SwiftUI
import ToyBoxUI

/// The empty sidebar's welcome, which connects right here, and why the last try failed under the
/// field. See Connecting in docs/spec.md.
struct SidebarWelcome: View {
    @Environment(AppModel.self) private var model
    @ViewState private var address = ""
    @ViewState private var isConnecting = false
    @ViewState private var failure: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28)).foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("Welcome to Toy Box").font(.headline)
                Text("Connect to one of your Macs to see its channels.").foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Server URL", text: $address, prompt: Text("machine.tail1234.ts.net"))
                    .textContentType(.URL)
                    .disabled(isConnecting)
                    .onSubmit(connect)
                if let failure {
                    Label {
                        Text(failure)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
            }
            Button(isConnecting ? "Connecting…" : "Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(20)
        .onChange(of: address) { _, _ in failure = nil }
    }

    private func connect() {
        guard !isConnecting, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isConnecting = true
        Task {
            do { _ = try await model.servers.connect(address) } catch { failure = error.localizedDescription }
            isConnecting = false
        }
    }
}

import ChannelClient
import SwiftUI

struct ConnectionSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @ViewState private var connection = ServerConnectionProbe()
    @ViewState private var useFailure: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Your channels run on your Mac. Keep it awake with Toy Box running, and connect both devices to Tailscale.")
                    Text("1. Connect both devices to Tailscale.")
                    Text("2. Enter your Mac's server address.")
                    Text("3. Test the connection, then continue.")
                }
            }
            ServerConnectionSection(connection: connection, requiresTest: true, currentServer: nil,
                                    onUse: connect, useFailure: $useFailure)
            Section {
                LabeledContent("Example") {
                    Text("http://your-mac.tailnet-name.ts.net:3100")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Connect to your Mac")
        .onAppear { connection.address = model.serverURL }
        .onDisappear { connection.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { connection.cancel() }
        }
    }

    private func connect() {
        guard case .connected(let url, _) = connection.phase else { return }
        do {
            try model.switchServer(to: url.absoluteString, replacing: model.serverURL)
            Task { await model.refreshCatalog() }
        } catch { useFailure = error.localizedDescription }
    }
}

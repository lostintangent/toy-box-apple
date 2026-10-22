import ChannelClient
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var serverURL = ""
    @ViewState private var result: String?
    @ViewState private var isTesting = false

    var body: some View {
        Form {
            TextField("Server URL", text: $serverURL)
                .onSubmit { model.configure(serverURL: serverURL) }
            Text("Use the same Toy Box server as your browser, including any path prefix.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(isTesting ? "Connecting..." : "Test Connection") {
                    isTesting = true
                    Task {
                        defer { isTesting = false }
                        do {
                            let catalog = try await ChannelAPI(serverURL: serverURL).catalog()
                            result = "Connected. \(catalog.channels.count) channels available."
                        } catch { result = error.localizedDescription }
                    }
                }
                .disabled(isTesting)
                Button("Use Server") { model.configure(serverURL: serverURL) }
                    .disabled(serverURL == model.serverURL)
            }
            if let result { Text(result).font(.caption).textSelection(.enabled) }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { serverURL = model.serverURL }
    }
}

import SwiftUI
import ToyBoxClient

/// A title menu's servers, by name and inline, each tagged with its address.
public struct ServerPicker: View {
    private let servers: ChannelServers
    @Binding private var selection: String

    public init(_ servers: ChannelServers, selection: Binding<String>) {
        (self.servers, _selection) = (servers, selection)
    }

    public var body: some View {
        Picker("Server", selection: $selection) {
            ForEach(servers.shown, id: \.api.baseURL) { catalog in
                Text(catalog.name).tag(catalog.api.baseURL.absoluteString)
            }
        }
        .pickerStyle(.inline)
        #if os(macOS)
        .labelsHidden()
        #endif
    }
}

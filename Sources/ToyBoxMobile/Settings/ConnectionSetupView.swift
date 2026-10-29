import ChannelClient
import SwiftUI

struct ConnectionSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewState private var connection = ServerConnectionProbe()
    @ViewState private var connectFailure: String?
    /// The Form's card edges and the bar's, measured so Continue lines up with the card at any width.
    @ViewState private var cardSpan: ClosedRange<CGFloat>?
    @ViewState private var barSpan: ClosedRange<CGFloat>?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    // Non-breaking spaces keep "Toy Box 👋" together when the heading wraps.
                    Text("Welcome to Toy\u{00A0}Box\u{00A0}👋")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Connect to your personal Toy Box server to start managing channels.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: ClosedRange<CGFloat>.self, of: \.horizontalSpan) { cardSpan = $0 }
                .listRowBackground(Color.clear)
                .listRowInsets(.horizontal, 0)
            }
            ServerConnectionSection(
                connection: connection, placeholder: "http://my-server:3100",
                footer: "Use your server's address, including its port and any path prefix. If it runs on another computer, this iPhone needs to reach it, for example over Tailscale.",
                failure: $connectFailure)
            // A pinned bar would cover the card at accessibility sizes, so Continue follows it instead.
            if dynamicTypeSize.isAccessibilitySize {
                Section {
                    continueButton
                        .listRowBackground(Color.clear)
                        .listRowInsets(.horizontal, 0)
                }
            }
        }
        .accessibilityIdentifier("server-setup")
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .safeAreaBar(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                continueButton
                    .padding(.leading, continueInsets?.leading)
                    .padding(.trailing, continueInsets?.trailing)
                    .padding(.bottom, 8)
                    .onGeometryChange(for: ClosedRange<CGFloat>.self, of: \.horizontalSpan) { barSpan = $0 }
            }
        }
        .onAppear { connection.address = model.serverURL }
        .onDisappear { connection.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { connection.cancel() }
        }
    }

    private var continueButton: some View {
        Button(action: connect) {
            Text("Continue")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .accessibilityIdentifier("server-use")
        .disabled(!canContinue)
    }

    private var continueInsets: (leading: CGFloat, trailing: CGFloat)? {
        guard let cardSpan, let barSpan else { return nil }
        return (max(0, cardSpan.lowerBound - barSpan.lowerBound), max(0, barSpan.upperBound - cardSpan.upperBound))
    }

    private var canContinue: Bool {
        guard case .connected? = connection.phase else { return false }
        return true
    }

    private func connect() {
        guard case .connected(let url, _) = connection.phase else { return }
        do {
            try model.switchServer(to: url.absoluteString, replacing: model.serverURL)
            Task { await model.refreshCatalog() }
        } catch { connectFailure = error.localizedDescription }
    }
}

private extension GeometryProxy {
    var horizontalSpan: ClosedRange<CGFloat> {
        let frame = frame(in: .global)
        return frame.minX...frame.maxX
    }
}

import ChannelClient
import SwiftUI
import ToyBoxUI

struct ConnectionSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewState private var address = ""
    @ViewState private var isConnecting = false
    @ViewState private var failure: (any Error)?
    /// The Form's card edges and the bar's, measured so Connect lines up with the card at any width.
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
            ServerConnectionSection(address: $address, failure: failure, connect: connect)
                .disabled(isConnecting)
            // A pinned bar would cover the card at accessibility sizes, so Connect follows it instead.
            if dynamicTypeSize.isAccessibilitySize {
                Section {
                    connectButton
                        .listRowBackground(Color.clear)
                        .listRowInsets(.horizontal, 0)
                }
            }
        }
        .accessibilityIdentifier("server-setup")
        .toolbarVisibility(.hidden, for: .navigationBar)
        .safeAreaBar(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                connectButton
                    .padding(.leading, continueInsets?.leading)
                    .padding(.trailing, continueInsets?.trailing)
                    .padding(.bottom, 8)
                    .onGeometryChange(for: ClosedRange<CGFloat>.self, of: \.horizontalSpan) { barSpan = $0 }
            }
        }
        .onAppear { address = model.serverURL }
        .onChange(of: address) { _, _ in failure = nil }
    }

    private var connectButton: some View {
        Button(action: connect) {
            Text(isConnecting ? "Connecting…" : "Connect")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .accessibilityIdentifier("server-connect")
        .disabled(isConnecting || isEmpty)
    }

    private var continueInsets: (leading: CGFloat, trailing: CGFloat)? {
        guard let cardSpan, let barSpan else { return nil }
        return (max(0, cardSpan.lowerBound - barSpan.lowerBound), max(0, barSpan.upperBound - cardSpan.upperBound))
    }

    private var isEmpty: Bool { address.trimmingCharacters(in: .whitespaces).isEmpty }

    /// One try: a server that answers is saved and replaces Welcome, and a failure shows in the card.
    private func connect() {
        guard !isConnecting, !isEmpty else { return }
        isConnecting = true
        Task {
            do { try await model.connect(address) } catch { failure = error }
            isConnecting = false
        }
    }
}

private extension GeometryProxy {
    var horizontalSpan: ClosedRange<CGFloat> {
        let frame = frame(in: .global)
        return frame.minX...frame.maxX
    }
}

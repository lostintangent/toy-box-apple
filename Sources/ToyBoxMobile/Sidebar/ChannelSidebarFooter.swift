import SwiftUI
import ToyBoxUI

struct ChannelSidebarFooter: View {
    let connection: SidebarConnection
    let busy: Bool
    let serverURL: String
    let error: String?
    let canRetry: Bool
    let retry: () -> Void
    let openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var showsProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading = connection.heading, let error {
                VStack(alignment: .leading, spacing: 4) {
                    Label(heading, systemImage: "wifi.exclamationmark")
                        .font(.footnote.weight(.semibold))
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 16) {
                        if canRetry {
                            Button("Retry", action: retry).frame(minHeight: 44)
                        }
                        Button("Settings", action: openSettings).frame(minHeight: 44)
                    }
                }
            }
            Button(action: openSettings) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(serverURL.isEmpty && error == nil ? .secondary : connection.dot)
                        .frame(width: 7, height: 7)
                        .opacity(showsProgress ? 0 : 1)
                        .overlay {
                            if showsProgress {
                                ProgressView().controlSize(.mini).fixedSize()
                            }
                        }
                    Text(serverURL.isEmpty ? "Choose a Server"
                         : "\(connection.verb) \(SidebarConnection.server(serverURL))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Server Settings")
            .accessibilityValue(serverURL.isEmpty ? "No server configured"
                                : "\(SidebarConnection.server(serverURL)), \(connection.accessibilityValue)")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .task(id: busy) {
            if busy {
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsProgress = busy }
        }
    }
}

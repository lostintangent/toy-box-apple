import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct OverviewAboutSection: View {
    let store: ChannelStore
    @Bindable var session: OverviewSession
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let details = store.details {
            let purpose = details.purpose.flatMap { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
            }
            let directory = details.directory.flatMap { $0.isEmpty ? nil : $0 }
            let preview = details.resolvedPreview
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        if let purpose {
                            OverviewPurpose(purpose: purpose, expanded: $session.purposeExpanded)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer(minLength: 0)
                        }
                        OverviewRootActions(store: store)
                    }
                    if directory != nil || preview != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            if let directory {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Folder on Mac", systemImage: "folder")
                                    Text(directory)
                                        .font(.footnote.monospaced())
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button("Copy Folder Path") { UIPasteboard.general.string = directory }
                                        .frame(minHeight: 44)
                                }
                            }
                            if let preview {
                                previewRow(preview)
                                if let error = session.previewError { ManagementError(message: error) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.borderless)
            }
            .listRowInsets(.vertical, 0)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .listSectionMargins(.vertical, 0)
            .listSectionMargins(.top, 12)
            .listSectionMargins(.bottom, 16)
        }
    }

    @ViewBuilder
    private func previewRow(_ preview: ChannelPreview) -> some View {
        if let address = previewAddress(preview) {
            Button {
                session.previewError = nil
                openURL(address) { accepted in
                    if !accepted { session.previewError = "The preview could not be opened." }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(preview.kind == "screen" ? "Screen Preview" : "Open Preview",
                          systemImage: preview.kind == "screen" ? "display" : "globe")
                    Text(preview.kind == "screen" ? (preview.screenId ?? "Screen") : address.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(ChannelInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 44, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                Text(preview.kind == "url" ? "The server did not provide a supported preview address."
                     : preview.kind == "screen" ? "The screen preview has no screen identity."
                     : "This preview type is not supported: \(preview.kind).")
                    .font(.footnote)
                    .foregroundStyle(ChannelInk.secondary)
            }
        }
    }

    private func previewAddress(_ preview: ChannelPreview) -> URL? {
        switch preview.kind {
        case "url": preview.url.flatMap(store.api.resourceURL)
        case "screen":
            preview.screenId?.isEmpty == false ? store.api.channelURL(channelID: store.id) : nil
        default: nil
        }
    }
}

private struct OverviewPurpose: View {
    let purpose: String
    @Binding var expanded: Bool
    @ViewState private var fullHeight: CGFloat = 0
    @ViewState private var shownHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(purpose)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { shownHeight = $0 }
                .background(alignment: .topLeading) {
                    Text(purpose)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { fullHeight = $0 }
                }
            if expanded || fullHeight > shownHeight + 0.5 {
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .frame(minHeight: 44)
            }
        }
    }
}

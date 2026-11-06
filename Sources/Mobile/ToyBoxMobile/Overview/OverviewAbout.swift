import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct OverviewAboutSection: View {
    let store: ChannelStore
    @Bindable var session: ChannelOverview
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(\.openURL) private var openURL

    /// Whether the headerless opening has a purpose, folder or preview to show. Without one it is
    /// omitted, and Team opens the list.
    static func hasContent(_ details: ChannelDetails?) -> Bool {
        purpose(of: details) != nil || directory(of: details) != nil || details?.resolvedPreview != nil
    }

    private static func purpose(of details: ChannelDetails?) -> String? {
        details?.purpose.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private static func directory(of details: ChannelDetails?) -> String? {
        details?.directory.flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        let purpose = Self.purpose(of: store.details)
        let directory = Self.directory(of: store.details)
        let preview = store.details?.resolvedPreview
        if Self.hasContent(store.details) {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    if let purpose {
                        OverviewPurpose(purpose: purpose, expanded: $session.purposeExpanded)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if directory != nil || preview != nil {
                        VStack(alignment: .leading, spacing: 0) {
                            if let directory {
                                OverviewFolderRow(directory: directory)
                                    .id(directory)
                            }
                            if let preview { previewRow(preview) }
                        }
                        .symbolRenderingMode(.monochrome)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .buttonStyle(.borderless)
                .listRowInsets(.vertical, 0)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
            .listSectionMargins(.bottom, OverviewListMetrics.sectionGap)
        }
    }

    @ViewBuilder
    private func previewRow(_ preview: ChannelPreview) -> some View {
        if preview.kind == "screen", let screenID = preview.screenId {
            // The app presents the viewer and holds Overview in place under it, so a rotation keeps it open.
            Button {
                app?.cover = .screen(screenID)
            } label: {
                previewTitle("Screen Preview", systemImage: "display")
                    .frame(minHeight: 44, alignment: .leading)
            }
        } else if preview.kind == "url", let address = preview.url.flatMap(store.api.resourceURL) {
            Button {
                openURL(address)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    previewTitle("Open Preview", systemImage: "globe")
                    Text(address.absoluteString)
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

    /// Only the title is link ink, since it is About's one real link. A hierarchical style here
    /// would resolve to the button's tint, so the icon names a concrete color.
    private func previewTitle(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.primary)
        }
    }
}

private struct OverviewFolderRow: View {
    let directory: String
    @ViewState private var copyToken: UUID?

    private var name: String { ChannelFolderName.name(of: directory) }

    var body: some View {
        HStack(spacing: 8) {
            Label(name, systemImage: "folder")
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.accessibility, Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Folder, \(name)")
                .accessibilityIdentifier("overview-folder")
            Button(action: copyPath) {
                Image(systemName: copyToken == nil ? "doc.on.doc" : "checkmark")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape([.interaction, .accessibility], Rectangle())
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Copy Path")
            .accessibilityValue(copyToken == nil ? "" : "Copied")
            .accessibilityIdentifier("overview-folder-copy")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Section(directory) {
                Button("Copy Path", systemImage: "doc.on.doc", action: copyPath)
            }
        }
        .sensoryFeedback(.success, trigger: copyToken) { _, token in token != nil }
        .task(id: copyToken) {
            guard let token = copyToken else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, copyToken == token else { return }
            copyToken = nil
        }
    }

    private func copyPath() {
        UIPasteboard.general.string = directory
        copyToken = UUID()
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
                Button(expanded ? "Show Less" : "Show More") { expanded.toggle() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
        }
    }
}

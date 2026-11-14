import ToyBoxClient
import ToyBoxKit
import QuickLook
import SwiftUI

/// A file the transcript can't show inline. Choosing it downloads it into the shared attachment
/// cache, inline or remote, and previews it with Quick Look.
public struct TranscriptFileRow: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    @ViewState private var preview: URL?
    @ViewState private var isLoading = false
    @ViewState private var failed = false

    public init(attachment: ChannelAttachment, api: ChannelAPI) {
        self.attachment = attachment
        self.api = api
    }

    public var body: some View {
        Button {
            Task { await open() }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.displayName).lineLimit(1).truncationMode(.middle)
                    if failed {
                        Text(Self.failure).font(.caption).foregroundStyle(.red)
                    } else if let kind = attachment.contentType?.localizedDescription {
                        Text(kind).font(.caption).foregroundStyle(ChannelInk.secondary)
                    }
                }
                // A long name truncates instead of widening the row past an image's width.
                .frame(maxWidth: 200, alignment: .leading)
            } icon: {
                if isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "doc") }
            }
            .font(.transcriptAttachment)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(.quaternary, in: .transcriptAttachment)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .quickLookPreview($preview)
    }

    #if os(iOS)
    private static let failure = "Couldn't open. Tap to try again."
    #else
    private static let failure = "Couldn't open. Click to try again."
    #endif

    private func open() async {
        isLoading = true
        defer { isLoading = false }
        do {
            preview = try await ChannelAttachmentCache.shared.file(for: attachment, api: api, reload: failed)
            failed = false
        } catch {
            failed = true
        }
    }
}

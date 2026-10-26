import ChannelClient
import ChannelKit
import SwiftUI

struct TranscriptAttachments: View {
    let attachments: [ChannelAttachment]
    let api: ChannelAPI
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                if attachment.mimeType?.hasPrefix("image/") == true {
                    TranscriptImage(attachment: attachment, api: api)
                } else {
                    TranscriptFileRow(attachment: attachment, api: api)
                }
            }
        }
    }
}

/// An image that reserves its box before it decodes, so arriving pixels resize it at most once.
private struct TranscriptImage: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    @State private var image: UIImage?
    @State private var failed = false
    @State private var showsProgress = false
    @State private var attempt = 0

    static let maximum = CGSize(width: 240, height: 160)
    static let unknown = CGSize(width: 120, height: 90)

    var body: some View {
        let size = image.map { Self.fitted($0.size) } ?? Self.unknown
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
                if failed {
                    Button("Retry", systemImage: "arrow.clockwise") { failed = false; attempt += 1 }
                        .font(.footnote)
                } else if showsProgress {
                    ProgressView()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(attachment.name ?? "Image")
        .task(id: attempt) { await load() }
    }

    private func load() async {
        guard image == nil else { return }
        let progress = Task { try await Task.sleep(for: .milliseconds(300)); showsProgress = true }
        defer { progress.cancel(); showsProgress = false }
        do {
            let data: Data
            if let base64 = attachment.base64, let decoded = Data(base64Encoded: base64) {
                data = decoded
            } else if let address = attachment.url, let url = api.resourceURL(address) {
                data = try await URLSession.shared.data(from: url).0
            } else { throw URLError(.badURL) }
            guard let decoded = await UIImage(data: data)?.byPreparingForDisplay() else { throw URLError(.cannotDecodeContentData) }
            image = decoded
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }

    static func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return unknown }
        let scale = min(1, maximum.width / size.width, maximum.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

private struct TranscriptFileRow: View {
    let attachment: ChannelAttachment
    let api: ChannelAPI
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let address = attachment.url, let url = api.resourceURL(address) { openURL(url) }
        } label: {
            Label {
                Text(attachment.name ?? "Attachment").lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: attachment.mimeType?.hasPrefix("video/") == true ? "film" : "doc")
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(attachment.url == nil)
    }
}

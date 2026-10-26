import ChannelClient
import SwiftUI

struct ComposerImageStrip: View {
    let draft: ComposerDraft
    let onReattach: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.images) { image in
                    ComposerImageTile(draft: draft, image: image, onReattach: onReattach)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .frame(minHeight: 88)
    }
}

private struct ComposerImageTile: View {
    let draft: ComposerDraft
    let image: ComposerImage
    let onReattach: (UUID) -> Void
    @ViewState private var loaded: (image: ComposerImage, bitmap: CGImage?)?

    var body: some View {
        let thumbnail = (loaded?.image == image ? loaded?.bitmap : nil) ?? draft.thumbnail(for: image)
        let unavailable = loaded?.image == image && thumbnail == nil
        VStack(spacing: 4) {
            Group {
                if let bitmap = thumbnail {
                    Image(decorative: bitmap, scale: 1).resizable().scaledToFill()
                } else if !unavailable {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading \(image.name)")
                } else {
                    Button { onReattach(image.id) } label: {
                        Image(systemName: "exclamationmark.triangle")
                            .frame(width: 56, height: 56)
                    }
                    .accessibilityLabel("Reattach \(image.name)")
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button { draft.removeImage(id: image.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
                .accessibilityLabel("Remove \(image.name)")
            }
            Text(image.name).font(.caption).lineLimit(1).frame(width: 56)
        }
        .task(id: image) {
            let decoded = await draft.loadThumbnail(for: image)
            guard !Task.isCancelled else { return }
            loaded = (image, decoded)
        }
    }
}

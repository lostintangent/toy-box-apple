import ChannelClient
import SwiftUI

struct ComposerImageStrip: View {
    let draft: ComposerDraft
    let onReattach: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.images) { image in
                    VStack(spacing: 4) {
                        Group {
                            if let bitmap = draft.thumbnail(for: image) {
                                Image(decorative: bitmap, scale: 1).resizable().scaledToFill()
                            } else {
                                Button(action: onReattach) {
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .frame(minHeight: 88)
    }
}

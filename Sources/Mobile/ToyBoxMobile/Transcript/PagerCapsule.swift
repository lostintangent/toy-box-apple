import SwiftUI

/// The glass capsule of thumbnails between Previous and Next, shared by the image and artifact viewers.
struct PagerCapsule<ID: Hashable, Thumbnail: View>: View {
    /// The singular noun in the Previous and Next labels, such as "Image".
    let noun: String
    /// The capsule's accessibility label, such as "Images".
    let label: String
    let ids: [ID]
    let selection: ID?
    let canShowPrevious: Bool
    let canShowNext: Bool
    let move: (Int) -> Void
    let select: (ID) -> Void
    /// Each item's spoken name and thumbnail, given its index in `ids`.
    let name: (Int) -> String
    @ViewBuilder let thumbnail: (Int) -> Thumbnail

    var body: some View {
        HStack(spacing: 6) {
            Button { move(-1) } label: {
                Label("Previous \(noun)", systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .disabled(!canShowPrevious)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                            item(id, index: index)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: selection, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .frame(maxWidth: CGFloat(min(9, ids.count)) * 50 - 6)
            Button { move(1) } label: {
                Label("Next \(noun)", systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .disabled(!canShowNext)
        }
        .buttonStyle(.plain)
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func item(_ id: ID, index: Int) -> some View {
        let selected = id == selection
        return Button { select(id) } label: {
            thumbnail(index)
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 6))
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 2) }
                }
                .padding(2)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name(index)), \(index + 1) of \(ids.count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(id)
    }
}

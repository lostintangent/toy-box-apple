import ToyBoxClient
import ToyBoxKit
import SwiftUI

/// A channel's avatar in its rounded square, as the pane's `ChannelAvatar` draws it: the project's
/// icon edge to edge, its mark on its color as members' marks are drawn, or a white # on cyan when
/// it has neither or its image fails to load. Pass the channel's server so an image can load.
public struct ChannelMark: View {
    public static let cyan = Color(.sRGB, red: 8.0 / 255, green: 145.0 / 255, blue: 178.0 / 255)
    private let avatar: ChannelAvatar?
    private let api: ChannelAPI?
    private let size: CGFloat
    private let symbolSize: CGFloat
    /// The last load's result, which matters only when the loader doesn't remember it.
    @ViewState private var loaded: (address: String, image: ChannelAvatarImages.Image)?
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ avatar: ChannelAvatar? = nil, api: ChannelAPI? = nil, size: CGFloat = 30,
                symbolSize: CGFloat? = nil) {
        self.avatar = avatar
        self.api = api
        self.size = size
        self.symbolSize = symbolSize ?? size * 14 / 30
    }

    /// Corners at 26% of the side, continuous like the system's icons.
    public static func shape(size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
    }

    private var shape: RoundedRectangle { Self.shape(size: size) }

    public var body: some View {
        face
            .frame(width: size, height: size)
            .clipShape(shape)
            .task(id: address) {
                guard let address, let api else { return }
                loaded = (address, await ChannelAvatarImages.shared.load(address, api: api))
            }
    }

    private var address: String? {
        if case .image(let address)? = avatar, api != nil { address } else { nil }
    }

    @ViewBuilder private var face: some View {
        switch avatar {
        case .image(let address)?:
            switch image(address) {
            case .loaded(let image)?:
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
            case .failed?:
                hash
            case nil:
                Color.clear
            }
        case .mark(let mark)?:
            if let face = AvatarFace(mark, size: size) { face } else { hash }
        case nil:
            hash
        }
    }

    private func image(_ address: String) -> ChannelAvatarImages.Image? {
        guard let api else { return .failed }
        if let image = ChannelAvatarImages.shared.image(address, api: api) { return image }
        return loaded?.address == address ? loaded?.image : nil
    }

    private var hash: some View {
        Image(systemName: "number")
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                if contrast == .increased {
                    Self.cyan
                } else {
                    Rectangle().fill(Self.cyan.gradient)
                }
            }
    }
}

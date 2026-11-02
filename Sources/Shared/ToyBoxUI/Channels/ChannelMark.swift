import SwiftUI

public struct ChannelMark: View {
    public static let cyan = Color(.sRGB, red: 8.0 / 255, green: 145.0 / 255, blue: 178.0 / 255)
    private let size: CGFloat
    private let symbolSize: CGFloat
    private let emphasized: Bool

    public init(size: CGFloat = 30, symbolSize: CGFloat? = nil, emphasized: Bool = false) {
        self.size = size
        self.symbolSize = symbolSize ?? size * 14 / 30
        self.emphasized = emphasized
    }

    public var body: some View {
        Image(systemName: "number")
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                if emphasized {
                    Circle().fill(Color.white.opacity(0.22))
                } else {
                    Circle().fill(Self.cyan.gradient)
                }
            }
    }
}

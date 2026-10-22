import AppKit
import ChannelKit
import SwiftUI

/// The shared agent avatar, matching the pane's `AgentAvatar`: the agent's 24-unit vector mark
/// stroked at 64% on its color, an initial when it has no profile, or a removed-agent symbol.
struct AgentAvatarView: View {
    let agent: ChannelAgent
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            if agent.deleted == true {
                Circle().fill(.quaternary)
                Image(systemName: "person.crop.circle.badge.xmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.6, height: size * 0.6)
                    .foregroundStyle(.secondary)
            } else if let avatar = agent.avatar, let fill = Color(hex: avatar.color),
                      let mark = try? SVGPath.parse(avatar.mark) {
                Circle().fill(fill)
                AvatarMark(path: mark)
                    .stroke(Color.contrastInk(forHex: avatar.color),
                            style: StrokeStyle(lineWidth: 2.25 * size * 0.64 / 24,
                                               lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.64, height: size * 0.64)
            } else {
                Circle().fill(Color.cyan.opacity(0.15))
                Text(agent.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Color.cyan)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Scales a 24 x 24 viewBox path into the frame it is drawn in.
private struct AvatarMark: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .translatedBy(x: rect.minX * 24 / rect.width, y: rect.minY * 24 / rect.height))
    }
}

extension Color {
    /// Parses `#rgb` or `#rrggbb` agent colors.
    init?(hex: String) {
        guard let rgb = Self.rgb(hex) else { return nil }
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Black or white, whichever contrasts more with the color, like CSS `contrast-color()`.
    static func contrastInk(forHex hex: String) -> Color {
        guard let rgb = rgb(hex) else { return .white }
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
        return 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.05 ? .white : .black
    }

    private static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }
}

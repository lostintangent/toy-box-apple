import AppKit
import ChannelKit
import SwiftUI

/// The shared agent avatar, matching the pane's `AgentAvatar`: the agent's 24-unit vector mark
/// stroked at 64% on its color, an initial when it has no profile, or a removed-agent symbol.
/// Profile colors fill with their soft top-light gradient so avatars read as slightly raised.
struct AgentAvatarView: View {
    let agent: ChannelAgent
    var size: CGFloat = 32
    @Environment(\.colorSchemeContrast) private var contrast

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
                      let mark = try? SVGPath.parse(avatar.mark),
                      let ink = resolvedAvatarInk(for: avatar).flatMap({ Color(hex: $0) }) {
                if contrast == .increased {
                    Circle().fill(fill)
                } else {
                    Circle().fill(fill.gradient)
                }
                AvatarMark(path: mark)
                    .stroke(ink,
                            style: StrokeStyle(lineWidth: 2.25 * size * 0.64 / 24,
                                               lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.64, height: size * 0.64)
            } else {
                Circle().fill(Color.cyan.opacity(0.15))
                Text(agent.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.primary)
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
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

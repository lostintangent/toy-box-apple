import Foundation

/// Resolves mark ink against the unlit sRGB background. Invalid backgrounds have no resolved ink.
public func resolvedAvatarInk(for avatar: AgentAvatar) -> String? {
    guard let background = AvatarColor(hex: avatar.color) else { return nil }
    if let ink = avatar.ink, ink.hasPrefix("#"), ink.count == 7,
       let foreground = AvatarColor(hex: ink) {
        let ratio = (max(background.luminance, foreground.luminance) + 0.05)
            / (min(background.luminance, foreground.luminance) + 0.05)
        if ratio >= 3 { return ink }
    }
    let whiteContrast = 1.05 / (background.luminance + 0.05)
    let blackContrast = (background.luminance + 0.05) / 0.05
    return whiteContrast >= blackContrast ? "#ffffff" : "#000000"
}

private struct AvatarColor {
    let luminance: Double

    init?(hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6,
              digits.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }), let value = UInt32(digits, radix: 16) else { return nil }
        func linear(_ component: UInt32) -> Double {
            let channel = Double(component) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        luminance = 0.2126 * linear((value >> 16) & 0xFF)
            + 0.7152 * linear((value >> 8) & 0xFF)
            + 0.0722 * linear(value & 0xFF)
    }
}

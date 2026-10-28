import ChannelKit
import SwiftUI

struct ChannelActivityLogo: View {
    enum Style {
        case fullColor, monochrome
    }

    var style: Style = .fullColor
    @Environment(\.colorScheme) private var colorScheme

    // Exact 1024-unit geometry from Resources/AppIcon.icon/Assets.
    static let headData = "M380 305.2 H644 A187 187 0 0 1 831 492.2 V591.2 A187 187 0 0 1 644 778.2 H426.2 C391 824.4 336 864 261.2 879.4 C294.2 837.6 305.2 795.8 300.8 758.4 A187 187 0 0 1 193 591.2 V492.2 A187 187 0 0 1 380 305.2 Z"
    static let smileData = "M465.8 617.6 A66 66 0 0 0 558.2 617.6"
    private static let head = try! SVGPath.parse(headData)
    private static let smile = try! SVGPath.parse(smileData)
    private static let stem = Path(roundedRect: .init(x: 492.2, y: 210.6, width: 39.6, height: 121),
                                   cornerRadius: 19.8)
    private static let antenna = Path(ellipseIn: .init(x: 461.4, y: 144.6, width: 101.2, height: 101.2))
    private static let visor = Path(roundedRect: .init(x: 265.6, y: 402, width: 492.8, height: 277.2),
                                    cornerRadius: 138.6)
    private static let eyes = [391.0, 571.4].map {
        Path(roundedRect: .init(x: $0, y: 468, width: 61.6, height: 110), cornerRadius: 30.8)
    }

    var body: some View {
        Canvas { context, size in
            let bounds = style == .fullColor ? CGRect(x: 0, y: 0, width: 1024, height: 1024)
                : CGRect(x: 193, y: 144.6, width: 638, height: 734.8)
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            context.translateBy(x: (size.width - bounds.width * scale) / 2,
                                y: (size.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            let monochrome = style == .monochrome
            let ink: GraphicsContext.Shading = monochrome ? .foreground : .color(
                colorScheme == .dark ? Color(red: 0.90196, green: 0.88627, blue: 0.85490)
                    : Color(red: 243 / 255, green: 239 / 255, blue: 230 / 255)
            )
            if !monochrome {
                let colors = colorScheme == .dark
                    ? [Color(red: 0.07059, green: 0.14902, blue: 0.33725),
                       Color(red: 0.01569, green: 0.04314, blue: 0.10196)]
                    : [Color(red: 0.10980, green: 0.25098, blue: 0.56078),
                       Color(red: 0.02745, green: 0.09804, blue: 0.21569)]
                context.fill(RoundedRectangle(cornerRadius: 224, style: .continuous).path(in: bounds),
                             with: .linearGradient(.init(colors: colors),
                                                   startPoint: .init(x: 512, y: 0),
                                                   endPoint: .init(x: 512, y: 1024)))
            }
            context.drawLayer { layer in
                layer.fill(Self.head, with: ink)
                layer.fill(Self.stem, with: ink)
                layer.fill(Self.antenna, with: monochrome ? ink : .color(
                    Color(red: 250 / 255, green: 204 / 255, blue: 21 / 255)
                ))
                if monochrome { layer.blendMode = .destinationOut }
                layer.fill(Self.visor, with: .color(Color(red: 10 / 255, green: 21 / 255, blue: 48 / 255)))
                layer.blendMode = .normal
                let face: GraphicsContext.Shading = monochrome ? .foreground
                    : .color(Color(red: 103 / 255, green: 232 / 255, blue: 249 / 255))
                for eye in Self.eyes { layer.fill(eye, with: face) }
                layer.stroke(Self.smile, with: face, style: .init(lineWidth: 26.4, lineCap: .round))
            }
        }
        .aspectRatio(style == .fullColor ? 1 : 638 / 734.8, contentMode: .fit)
    }
}

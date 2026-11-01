import AppKit

/// The menu bar item's robot head: the app icon's own head path with the visor knocked out, as one
/// template image per state. Every state shares a 17 by 16 point canvas with room for the badge,
/// so the item never changes width. AppKit loads the SVG natively and the status item tints it.
enum MenuBarIcon: CaseIterable {
    case face, working, waiting

    @MainActor var image: NSImage {
        switch self {
        case .face: Self.faceImage
        case .working: Self.workingImage
        case .waiting: Self.waitingImage
        }
    }

    @MainActor private static let faceImage = load(.face)
    @MainActor private static let workingImage = load(.working)
    @MainActor private static let waitingImage = load(.waiting)

    private static func load(_ icon: MenuBarIcon) -> NSImage {
        guard let image = NSImage(data: Data(icon.svg.utf8)) else {
            preconditionFailure("The menu bar's \(icon) image didn't load")
        }
        image.isTemplate = true
        return image
    }

    var svg: String {
        let body = switch self {
        case .face: Self.headSVG + Self.faceSVG
        case .working: Self.headSVG + Self.dotsSVG
        case .waiting: Self.gapMaskSVG + #"<g mask="url(#gap)">"# + Self.headSVG + Self.faceSVG + "</g>" + Self.badgeSVG
        }
        return #"<svg xmlns="http://www.w3.org/2000/svg" width="17" height="16" viewBox="193 131 795.2 748.4">"#
            + body + "</svg>"
    }

    private static let headSVG = #"<path fill-rule="evenodd" d="M380 305.2H644A187 187 0 0 1 831 492.2V591.2A187 187 0 0 1 644 778.2H426.2C391 824.4 336 864 261.2 879.4C294.2 837.6 305.2 795.8 300.8 758.4A187 187 0 0 1 193 591.2V492.2A187 187 0 0 1 380 305.2ZM419.5 375.2H604.5A166.5 166.5 0 0 1 604.5 708.2H419.5A166.5 166.5 0 0 1 419.5 375.2Z"/><rect x="484" y="214" width="56" height="110" rx="28"/><circle cx="512" cy="195" r="64"/>"#
    private static let faceSVG = ##"<rect x="384.8" y="459.7" width="74" height="128" rx="37"/><rect x="565.2" y="459.7" width="74" height="128" rx="37"/><path d="M462 619.7A68 68 0 0 0 562 619.7" fill="none" stroke="#000" stroke-width="48" stroke-linecap="round"/>"##
    private static let dotsSVG = #"<circle cx="378" cy="541.7" r="42"/><circle cx="512" cy="541.7" r="42"/><circle cx="646" cy="541.7" r="42"/>"#
    private static let gapMaskSVG = ##"<mask id="gap" maskUnits="userSpaceOnUse" x="193" y="131" width="795.2" height="748.4"><rect x="193" y="131" width="795.2" height="748.4" fill="#fff"/><circle cx="830" cy="281" r="202"/></mask>"##
    private static let badgeSVG = #"<circle cx="830" cy="281" r="150"/>"#
}

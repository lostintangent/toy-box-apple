import AppKit
import UniformTypeIdentifiers

@MainActor
final class QuickSendIntake: NSObject {
    private let present: (QuickSendPrefill) throws -> Void
    private(set) var hasReceivedContent = false

    init(present: @escaping (QuickSendPrefill) throws -> Void) {
        self.present = present
    }

    @objc(sendToToyBox:userData:error:)
    func sendToToyBox(_ pasteboard: NSPasteboard, userData: String?,
                      error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do {
            try receive(Self.read(pasteboard))
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }

    func openFiles(_ paths: [String]) throws {
        guard !paths.isEmpty else { throw IntakeError.empty }
        try receive(.init(fileURLs: paths.map { URL(fileURLWithPath: $0) }))
    }

    func openSharedURL(_ url: URL) throws {
        let name = try Self.sharedPasteboardName(in: url)
        let pasteboard = NSPasteboard(name: .init(name))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        try receive(Self.read(pasteboard))
    }

    static func sharedPasteboardName(in url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "toybox-desktop",
              components.host?.lowercased() == "quick-send",
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let query = components.queryItems, query.count == 1,
              query[0].name == "pasteboard", let name = query[0].value,
              name.hasPrefix("dev.toybox.desktop.share."),
              UUID(uuidString: String(name.dropFirst("dev.toybox.desktop.share.".count))) != nil else {
            throw IntakeError.invalidHandoff
        }
        return name
    }

    private func receive(_ prefill: QuickSendPrefill) throws {
        try present(prefill)
        hasReceivedContent = true
    }

    static func read(_ pasteboard: NSPasteboard) throws -> QuickSendPrefill {
        var text: [String] = []
        var files: [URL] = []
        var images: [ComposerImage] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let value = item.string(forType: .fileURL) {
                guard let url = URL(string: value), url.isFileURL else { throw IntakeError.unreadableFile }
                files.append(url)
            } else if let image = try image(from: item) {
                images.append(image)
            } else if let value = item.string(forType: .string) ?? item.string(forType: .URL), !value.isEmpty {
                text.append(value)
            } else {
                throw IntakeError.empty
            }
        }
        guard !text.isEmpty || !files.isEmpty || !images.isEmpty else { throw IntakeError.empty }
        return .init(text: text.joined(separator: "\n\n"), fileURLs: files, images: images)
    }

    private static func image(from item: NSPasteboardItem) throws -> ComposerImage? {
        guard let imageIndex = item.types.firstIndex(where: {
            UTType($0.rawValue)?.conforms(to: .image) == true
        }) else { return nil }
        if let textIndex = item.types.firstIndex(where: {
            [.string, .rtf, .rtfd, .html, .URL].contains($0)
                || UTType($0.rawValue)?.conforms(to: .text) == true
        }), textIndex < imageIndex { return nil }
        let types = item.types.filter { UTType($0.rawValue)?.conforms(to: .image) == true }
        for uniform in [UTType.png, .jpeg, .gif, .webP] {
            guard let type = types.first(where: { UTType($0.rawValue)?.conforms(to: uniform) == true }),
                  let data = item.data(forType: type), NSBitmapImageRep(data: data) != nil,
                  let mime = uniform.preferredMIMEType else { continue }
            return .init(name: "Shared image.\(uniform.preferredFilenameExtension ?? "png")",
                         mimeType: mime, data: data)
        }
        for type in types {
            guard let data = item.data(forType: type), let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            return .init(name: "Shared image.png", mimeType: "image/png", data: png)
        }
        throw IntakeError.unreadableImage
    }

    enum IntakeError: LocalizedError {
        case empty, unreadableFile, unreadableImage, unavailable, invalidHandoff

        var errorDescription: String? {
            switch self {
            case .empty: "Send to Toy Box needs selected text, a URL, an image or a file."
            case .unreadableFile: "The selected file could not be read. Try dropping the original file on Toy Box."
            case .unreadableImage: "The selected image could not be read. Try the original image file."
            case .unavailable: "Quick Send is unavailable in this launch."
            case .invalidHandoff: "Toy Box couldn't open this shared content. Please share it again."
            }
        }
    }
}

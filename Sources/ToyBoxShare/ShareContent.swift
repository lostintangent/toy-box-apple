import AppKit
import UniformTypeIdentifiers

enum ShareContent: Equatable, Sendable {
    case text(String)
    case url(URL)
    case file(URL)
    case image(Data, type: String)

    enum Failure: LocalizedError {
        case empty, unsupported, invalidItem, pasteboard, temporaryFile

        var errorDescription: String? {
            switch self {
            case .empty: "There is no content to send to Toy Box."
            case .unsupported: "This item cannot be shared with Toy Box. Share text, a URL, an image or a file."
            case .invalidItem: "The source app could not provide the shared item."
            case .pasteboard: "The shared content could not be passed to Toy Box."
            case .temporaryFile: "Temporary non-image files cannot be sent to Toy Box. Share the original file from Finder."
            }
        }
    }

    @MainActor
    static func load(_ input: [Any]) async throws -> [ShareContent] {
        var result: [ShareContent] = []
        for case let item as NSExtensionItem in input {
            let providers = item.attachments ?? []
            var loaded: [ShareContent] = []
            for provider in providers {
                loaded.append(try await load(provider))
            }
            if let text = item.attributedContentText?.string, !text.isEmpty {
                let duplicated = loaded.contains { content in
                    switch content {
                    case let .text(value): value == text
                    case let .url(value): value.absoluteString == text
                    default: false
                    }
                }
                if !duplicated { loaded.insert(.text(text), at: 0) }
            }
            result.append(contentsOf: loaded)
        }
        guard !result.isEmpty else { throw Failure.empty }
        return result
    }

    @MainActor
    static func load(_ provider: NSItemProvider) async throws -> ShareContent {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let data = try await data(from: provider, type: UTType.fileURL.identifier)
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw Failure.invalidItem
            }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try image(Data(contentsOf: url), type: type)
            }
            return .file(try inPlaceFile(url))
        }
        if let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }), let type = UTType(identifier) {
            return try image(try await data(from: provider, type: identifier), type: type)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let data = try await data(from: provider, type: UTType.url.identifier)
            guard let url = URL(dataRepresentation: data, relativeTo: nil), !url.isFileURL else {
                throw Failure.invalidItem
            }
            return .url(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
            let data = try await data(from: provider, type: UTType.utf8PlainText.identifier)
            let text: String?
            if data.starts(with: Data("bplist00".utf8)) {
                text = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data) as String?
            } else {
                text = String(data: data, encoding: .utf8)
            }
            guard let text, !text.isEmpty else { throw Failure.invalidItem }
            return .text(text)
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                _ = provider.loadObject(ofClass: NSString.self) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let text = value as? String, !text.isEmpty { continuation.resume(returning: text) }
                    else { continuation.resume(throwing: Failure.invalidItem) }
                }
            }
            return .text(value)
        }
        if provider.registeredTypeIdentifiers.contains(where: {
            UTType($0)?.conforms(to: .data) == true || UTType($0)?.conforms(to: .content) == true
        }) {
            throw Failure.temporaryFile
        }
        throw Failure.unsupported
    }

    nonisolated static func inPlaceFile(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let temporary = ["/tmp/", "/private/tmp/", "/var/", "/private/var/"].contains { path.hasPrefix($0) }
            || path.contains("/tmp/") || path.contains("/TemporaryItems/")
        let container = path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
        guard url.isFileURL, !temporary, !container else { throw Failure.temporaryFile }
        return url
    }

    @MainActor
    private static func data(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: Failure.invalidItem) }
            }
        }
    }

    @MainActor
    private static func image(_ data: Data, type: UTType) throws -> ShareContent {
        let supported: [UTType] = [.png, .jpeg, .gif, .webP, .tiff]
        if let type = supported.first(where: { type.conforms(to: $0) }) {
            return .image(data, type: type.identifier)
        }
        guard let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.invalidItem }
        return .image(png, type: UTType.png.identifier)
    }

    @MainActor
    static func write(_ content: [ShareContent], to pasteboard: NSPasteboard) throws -> URL {
        guard !content.isEmpty else { throw Failure.empty }
        let items = content.map { content in
            let item = NSPasteboardItem()
            switch content {
            case let .text(value):
                item.setString(value, forType: .string)
            case let .url(value):
                item.setString(value.absoluteString, forType: .URL)
                item.setString(value.absoluteString, forType: .string)
            case let .file(value):
                item.setString(value.absoluteString, forType: .fileURL)
            case let .image(data, type):
                item.setData(data, forType: .init(type))
            }
            return item
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { throw Failure.pasteboard }
        var url = URLComponents()
        url.scheme = "toybox-desktop"
        url.host = "quick-send"
        url.queryItems = [.init(name: "pasteboard", value: pasteboard.name.rawValue)]
        guard let result = url.url else { throw Failure.pasteboard }
        return result
    }
}

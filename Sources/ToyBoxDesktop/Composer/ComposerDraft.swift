import AppKit
import ChannelKit
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct ComposerImage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var mimeType: String
    var data: Data

    var attachment: ChannelAttachment {
        .init(name: name, mimeType: mimeType, base64: data.base64EncodedString())
    }

    var image: NSImage? { NSImage(data: data) }
}

@MainActor @Observable
final class ComposerDraft {
    private struct SavedImage: Codable {
        var id: UUID
        var name: String
        var mimeType: String
    }

    private struct Saved: Codable {
        var text: String
        var images: [SavedImage]
        var sendAttemptID: String?
    }

    private static var drafts: [String: ComposerDraft] = [:]
    var text = "" {
        didSet {
            if text != oldValue {
                revision = UUID()
                sendAttemptID = nil
                save()
            }
        }
    }
    private(set) var images: [ComposerImage] = []
    private(set) var revision = UUID()
    private var loadingImageCount = 0
    private(set) var sendAttemptID: String?
    private(set) var isSavedLocally = true
    var error: String?
    private let fileURL: URL?
    private let imagesURL: URL?
    private var restoring = true

    static func storageKey(serverURL: URL, channelID: String) -> String {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        if (components?.scheme == "http" && components?.port == 80)
            || (components?.scheme == "https" && components?.port == 443) {
            components?.port = nil
        }
        let normalized = (components?.string ?? serverURL.absoluteString)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return SHA256.hash(data: Data("\(normalized)\n\(channelID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func shared(serverURL: URL, channelID: String) -> ComposerDraft {
        let key = storageKey(serverURL: serverURL, channelID: channelID)
        if let draft = drafts[key] { return draft }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let fileURL = support.appendingPathComponent("ToyBoxDesktop/Drafts", isDirectory: true)
            .appendingPathComponent("\(key).json")
        let draft = ComposerDraft(fileURL: fileURL)
        drafts[key] = draft
        return draft
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        imagesURL = fileURL?.deletingPathExtension()
        isSavedLocally = fileURL != nil
        if let fileURL, let imagesURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: fileURL))
                text = saved.text
                sendAttemptID = saved.sendAttemptID
                for image in saved.images {
                    do {
                        let data = try Data(contentsOf: imagesURL.appendingPathComponent(image.id.uuidString))
                        images.append(.init(id: image.id, name: image.name, mimeType: image.mimeType, data: data))
                    } catch {
                        images.append(.init(id: image.id, name: image.name, mimeType: image.mimeType, data: Data()))
                        self.error = "\(image.name) could not be restored. Remove it and attach the image again: \(error.localizedDescription)"
                    }
                }
                if images.contains(where: { $0.image == nil }), error == nil {
                    error = "A saved image cannot be decoded. Remove it and attach the image again."
                }
            } catch {
                self.error = "The saved draft could not be restored: \(error.localizedDescription)"
                isSavedLocally = false
            }
        }
        restoring = false
    }

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    var hasUnreadableImage: Bool { images.contains { $0.image == nil } }
    var isLoadingImages: Bool { loadingImageCount > 0 }

    func removeImage(id: UUID) {
        images.removeAll { $0.id == id }
        revision = UUID()
        sendAttemptID = nil
        save()
    }

    func append(_ image: ComposerImage) {
        guard image.image != nil else {
            error = "\(image.name) cannot be decoded as an image. Attach a readable image file."
            return
        }
        images.append(image)
        revision = UUID()
        sendAttemptID = nil
        save()
    }

    func attachFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        loadingImageCount += 1
        Task {
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let image = try await Task.detached {
                        let resource = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
                        guard resource.isRegularFile == true, let type = resource.contentType,
                              type.conforms(to: .image), let mime = type.preferredMIMEType else {
                            throw ImageError.unsupported
                        }
                        return ComposerImage(name: url.lastPathComponent, mimeType: mime,
                                             data: try Data(contentsOf: url))
                    }.value
                    append(image)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            loadingImageCount -= 1
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }

    @discardableResult
    func attachProvider(_ provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            loadingImageCount += 1
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                Task { @MainActor in
                    if let url { self.attachFiles([url]) }
                    else {
                        self.error = "This image could not be opened: \(error?.localizedDescription ?? "The dropped file has no readable URL.")"
                    }
                    self.loadingImageCount -= 1
                }
            }
            return true
        }
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }), let type = UTType(identifier), let mimeType = type.preferredMIMEType else {
            error = "Drop an image file to attach it to this message."
            return false
        }
        loadingImageCount += 1
        let name = provider.suggestedName ?? "Dropped image"
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
            Task { @MainActor in
                if let data {
                    self.append(.init(name: name, mimeType: mimeType, data: data))
                } else {
                    self.error = "The dropped image could not be read: \(error?.localizedDescription ?? "No image data was provided.")"
                }
                self.loadingImageCount -= 1
            }
        }
        return true
    }

    func restore(content: String, attachments: [ChannelAttachment], sendAttemptID: String? = nil) {
        text = content
        images = attachments.map { attachment in
            let data: Data
            if let encoded = attachment.base64, let decoded = Data(base64Encoded: encoded),
               let mimeType = attachment.mimeType, !mimeType.isEmpty {
                data = decoded
            } else {
                data = Data()
            }
            return ComposerImage(name: attachment.name ?? "Attached image",
                                 mimeType: attachment.mimeType ?? "", data: data)
        }
        revision = UUID()
        self.sendAttemptID = sendAttemptID
        if hasUnreadableImage {
            error = "Some images from this send are unavailable. Remove them and attach the images again before sending."
        }
        save()
    }

    func clear(ifUnchanged revision: UUID) {
        guard self.revision == revision else { return }
        text = ""
        images = []
        sendAttemptID = nil
        self.revision = UUID()
        save()
    }

    func associateSend(id: String) {
        sendAttemptID = id
        save()
    }

    private func save() {
        guard !restoring, let fileURL, let imagesURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            for image in images where !image.data.isEmpty {
                let imageURL = imagesURL.appendingPathComponent(image.id.uuidString)
                if !FileManager.default.fileExists(atPath: imageURL.path) {
                    try image.data.write(to: imageURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
                }
            }
            let metadata = images.map { SavedImage(id: $0.id, name: $0.name, mimeType: $0.mimeType) }
            let encoded = try JSONEncoder().encode(Saved(text: text, images: metadata, sendAttemptID: sendAttemptID))
            try encoded.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let retained = Set(images.map { $0.id.uuidString })
            for url in try FileManager.default.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil)
                where !retained.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
            isSavedLocally = true
        } catch {
            isSavedLocally = false
            self.error = "This draft could not be saved locally: \(error.localizedDescription)"
        }
    }

    private enum ImageError: LocalizedError {
        case unsupported
        var errorDescription: String? {
            switch self {
            case .unsupported: "Choose an image file. Other attachment formats are not supported."
            }
        }
    }
}

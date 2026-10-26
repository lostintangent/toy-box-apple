import ChannelKit
import CoreGraphics
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

public struct ComposerImage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mimeType: String
    public var data: Data

    public init(id: UUID = UUID(), name: String, mimeType: String, data: Data) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }

    public var attachment: ChannelAttachment {
        .init(name: name, mimeType: mimeType, base64: data.base64EncodedString())
    }
}

@MainActor @Observable
public final class ComposerDraft {
    public enum Scope: Hashable {
        case conversation
        case quickSend
        case quickSendIncoming
        case inboxReply(sequence: Int)

        fileprivate var storageComponent: String? {
            switch self {
            case .conversation: nil
            case .quickSend: "quick-send"
            case .quickSendIncoming: "quick-send-incoming"
            case .inboxReply(let sequence): "inbox-reply:\(sequence)"
            }
        }
    }

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
    public var text = "" {
        didSet {
            if text != oldValue {
                let wasAttempted = sendAttemptID != nil
                revision = UUID()
                sendAttemptID = nil
                save()
                if wasAttempted { normalizeUnsentImages() }
            }
        }
    }
    public private(set) var images: [ComposerImage] = []
    public private(set) var revision = UUID()
    private var loadingImageCount = 0
    private var failedImageIDs: Set<UUID> = []
    private var changedImageIDs: Set<UUID> = []
    private var reattachments: [UUID: UUID] = [:]
    public private(set) var sendAttemptID: String?
    public private(set) var isSavedLocally = true
    public private(set) var isNew = true
    public var error: String?
    private let fileURL: URL?
    private let imagesURL: URL?
    private let imageIsReadable: @MainActor (Data) -> Bool
    // AppKit also renders SVG sources for which ImageIO reports zero images.
    private let rasterizeImage: (@Sendable (Data, Int) -> CGImage?)?
    private var restoring = true

    public static func storageKey(serverURL: URL, channelID: String, scope: Scope = .conversation) -> String {
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
        let identity = "\(normalized)\n\(channelID)" + (scope.storageComponent.map { "\n\($0)" } ?? "")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func shared(serverURL: URL, channelID: String, scope: Scope = .conversation,
                              imageIsReadable: @escaping @MainActor (Data) -> Bool,
                              rasterizeImage: (@Sendable (Data, Int) -> CGImage?)? = nil) -> ComposerDraft {
        let key = storageKey(serverURL: serverURL, channelID: channelID, scope: scope)
        if let draft = drafts[key] { return draft }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let fileURL = support.appendingPathComponent("ToyBoxDesktop/Drafts", isDirectory: true)
            .appendingPathComponent("\(key).json")
        let draft = ComposerDraft(fileURL: fileURL, imageIsReadable: imageIsReadable, rasterizeImage: rasterizeImage)
        drafts[key] = draft
        return draft
    }

    public init(fileURL: URL? = nil, imageIsReadable: @escaping @MainActor (Data) -> Bool,
                rasterizeImage: (@Sendable (Data, Int) -> CGImage?)? = nil) {
        self.imageIsReadable = imageIsReadable
        self.rasterizeImage = rasterizeImage
        self.fileURL = fileURL
        imagesURL = fileURL?.deletingPathExtension()
        isSavedLocally = fileURL != nil
        if let fileURL, let imagesURL, FileManager.default.fileExists(atPath: fileURL.path) {
            isNew = false
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
                if images.contains(where: { !imageIsReadable($0.data) }), error == nil {
                    error = "A saved image cannot be decoded. Remove it and attach the image again."
                }
            } catch {
                self.error = "The saved draft could not be restored: \(error.localizedDescription)"
                isSavedLocally = false
            }
        }
        restoring = false
        normalizeUnsentImages()
    }

    public var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    public var hasUnreadableImage: Bool {
        images.contains { failedImageIDs.contains($0.id) || !imageIsReadable($0.data) }
    }
    public var isLoadingImages: Bool { loadingImageCount > 0 }

    public func removeImage(id: UUID) {
        images.removeAll { $0.id == id }
        failedImageIDs.remove(id)
        reattachments[id] = nil
        editAsNewMessage()
    }

    /// Keeps the original slot and attempted payload until preparation succeeds.
    /// A removed or superseded slot is never restored by an older operation.
    @discardableResult
    public func reattachImage(id: UUID, from url: URL) async -> Bool {
        guard let original = images.first(where: { $0.id == id }) else {
            error = "\(url.lastPathComponent) could not be reattached because the original attachment was removed."
            return false
        }
        let token = UUID()
        let previousError = error
        reattachments[id] = token
        loadingImageCount += 1
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            loadingImageCount -= 1
            if reattachments[id] == token { reattachments[id] = nil }
        }
        do {
            let reading = Task.detached { try Self.importFile(url, allowingLocalPaths: false) }
            let imported = try await withTaskCancellationHandler {
                try await reading.value
            } onCancel: {
                reading.cancel()
            }
            try Task.checkCancellation()
            guard case .image(var image) = imported else { throw ImageError.unsupported }
            guard imageIsReadable(image.data) else { throw ImageError.unreadable }
            image.id = id
            let prepared = try await prepareImage(image)
            try Task.checkCancellation()
            guard reattachments[id] == token, images.contains(original) else { return false }
            replacePrepared(prepared, original: original, asNewMessage: true)
            if !hasUnreadableImage, error == previousError, fileURL == nil || isSavedLocally { error = nil }
            return true
        } catch {
            guard reattachments[id] == token, images.contains(original) else { return false }
            self.error = error is CancellationError
                ? "\(url.lastPathComponent) was not reattached because image preparation was cancelled."
                : "\(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    public func append(_ image: ComposerImage) {
        guard imageIsReadable(image.data) else {
            error = "\(image.name) cannot be decoded as an image. Attach a readable image file."
            return
        }
        if let prepared = ComposerImageEncoding.passthrough(image) {
            appendPrepared(prepared)
        } else {
            editAsNewMessage()
            normalize(image, replacingSavedImage: false)
        }
    }

    private func appendPrepared(_ image: ComposerImage) {
        images.append(image)
        editAsNewMessage()
    }

    public func thumbnail(for image: ComposerImage) -> CGImage? {
        failedImageIDs.contains(image.id) ? nil : ComposerThumbnails.image(for: image, rasterize: rasterizeImage)
    }

    private func normalizeUnsentImages() {
        guard !restoring, sendAttemptID == nil else { return }
        for image in images where imageIsReadable(image.data) {
            if let prepared = ComposerImageEncoding.passthrough(image) {
                if prepared != image { replacePrepared(prepared, original: image) }
            } else {
                normalize(image, replacingSavedImage: true)
            }
        }
    }

    private func normalize(_ image: ComposerImage, replacingSavedImage: Bool) {
        loadingImageCount += 1
        Task {
            defer { loadingImageCount -= 1 }
            do {
                let prepared = try await prepareImage(image)
                if replacingSavedImage { replacePrepared(prepared, original: image) }
                else { appendPrepared(prepared) }
            } catch {
                if replacingSavedImage {
                    guard images.contains(image), sendAttemptID == nil else { return }
                    failedImageIDs.insert(image.id)
                }
                self.error = "\(image.name): \(error.localizedDescription)"
            }
        }
    }

    private func prepareImage(_ image: ComposerImage) async throws -> ComposerImage {
        let rasterize = rasterizeImage
        let preparing = Task.detached {
            try Task.checkCancellation()
            if let prepared = ComposerImageEncoding.passthrough(image) {
                try Task.checkCancellation()
                return prepared
            }
            let fallback = ComposerImageEncoding.needsNativeRasterization(image.data)
                ? rasterize?(image.data, ComposerImageEncoding.maximumDimension) : nil
            try Task.checkCancellation()
            let prepared = try ComposerImageEncoding.normalize(image, fallback: fallback)
            try Task.checkCancellation()
            return prepared
        }
        return try await withTaskCancellationHandler {
            try await preparing.value
        } onCancel: {
            preparing.cancel()
        }
    }

    private func replacePrepared(_ image: ComposerImage, original: ComposerImage, asNewMessage: Bool = false) {
        guard asNewMessage || sendAttemptID == nil, let index = images.firstIndex(of: original) else { return }
        if image.data != original.data {
            changedImageIDs.insert(image.id)
            ComposerThumbnails.remove(id: original.id)
        }
        images[index] = image
        failedImageIDs.remove(image.id)
        if asNewMessage { editAsNewMessage() }
        else {
            revision = UUID()
            save()
        }
    }

    public func attachFiles(_ urls: [URL]) {
        attachFiles(urls, allowingLocalPaths: false)
    }

    public func attachFiles(_ urls: [URL], allowingLocalPaths: Bool) {
        guard !urls.isEmpty else { return }
        loadingImageCount += 1
        Task {
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let imported = try await Task.detached {
                        try Self.importFile(url, allowingLocalPaths: allowingLocalPaths)
                    }.value
                    switch imported {
                    case .image(let image): append(image)
                    case .path(let path): text = joinedComposerText(text, path)
                    }
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
    public func attachProvider(_ provider: NSItemProvider) -> Bool {
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

    public func restore(content: String, attachments: [ChannelAttachment], sendAttemptID: String? = nil) {
        restoring = true
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
        failedImageIDs = []
        restoring = false
        if hasUnreadableImage {
            error = "Some images from this send are unavailable. Remove them and attach the images again before sending."
        }
        normalizeUnsentImages()
        save()
    }

    public func clear(ifUnchanged revision: UUID) {
        guard self.revision == revision else { return }
        restoring = true
        text = ""
        images = []
        failedImageIDs = []
        sendAttemptID = nil
        self.revision = UUID()
        restoring = false
        save()
    }

    public func associateSend(id: String) {
        sendAttemptID = id
        save()
    }

    public func editAsNewMessage() {
        let wasAttempted = sendAttemptID != nil
        sendAttemptID = nil
        revision = UUID()
        save()
        if wasAttempted { normalizeUnsentImages() }
    }

    public func append(contentsOf other: ComposerDraft) {
        guard other !== self else { return }
        text = joinedComposerText(text, other.text)
        for image in other.images {
            var copy = image
            copy.id = UUID()
            if imageIsReadable(copy.data) { append(copy) }
            else { images.append(copy) }
        }
        if !other.images.isEmpty {
            editAsNewMessage()
        }
        if let error = other.error { self.error = error }
        save()
    }

    func append(content: String, attachments: [ChannelAttachment]) {
        let recovered = ComposerDraft(imageIsReadable: imageIsReadable, rasterizeImage: rasterizeImage)
        recovered.restore(content: content, attachments: attachments)
        append(contentsOf: recovered)
    }

    @MainActor
    private enum ComposerThumbnails {
        private final class Entry {
            let image: CGImage?
            init(_ image: CGImage?) { self.image = image }
        }

        private static let cache: NSCache<NSUUID, Entry> = {
            let cache = NSCache<NSUUID, Entry>()
            cache.countLimit = 128
            cache.totalCostLimit = 16 * 1024 * 1024
            return cache
        }()

        static func image(for image: ComposerImage,
                          rasterize: (@Sendable (Data, Int) -> CGImage?)?) -> CGImage? {
            let key = image.id as NSUUID
            if let cached = cache.object(forKey: key) { return cached.image }
            let thumbnail = ChannelImageDecoder.thumbnail(
                data: image.data, maxPixelSize: ComposerImageEncoding.thumbnailDimension
            ) ?? rasterize?(image.data, ComposerImageEncoding.thumbnailDimension)
            cache.setObject(Entry(thumbnail), forKey: key,
                            cost: thumbnail.map { $0.bytesPerRow * $0.height } ?? 0)
            return thumbnail
        }

        static func remove(id: UUID) { cache.removeObject(forKey: id as NSUUID) }
    }

    public func retrySave() {
        error = nil
        save()
    }

    private func save() {
        isNew = false
        guard !restoring, let fileURL, let imagesURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            for image in images where !image.data.isEmpty {
                let imageURL = imagesURL.appendingPathComponent(image.id.uuidString)
                if changedImageIDs.contains(image.id) || !FileManager.default.fileExists(atPath: imageURL.path) {
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
            changedImageIDs = []
            isSavedLocally = true
        } catch {
            isSavedLocally = false
            self.error = "This draft could not be saved locally: \(error.localizedDescription)"
        }
    }

    private enum ImportedFile: Sendable {
        case image(ComposerImage)
        case path(String)
    }

    private nonisolated static func importFile(_ url: URL, allowingLocalPaths: Bool) throws -> ImportedFile {
        try Task.checkCancellation()
        guard url.isFileURL else { throw ImageError.unsupported }
        let resource = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
        guard resource.isRegularFile == true else { throw ImageError.unsupported }
        let imported: ImportedFile
        if let type = resource.contentType, type.conforms(to: .image), let mime = type.preferredMIMEType {
            imported = .image(ComposerImage(name: url.lastPathComponent, mimeType: mime,
                                           data: try Data(contentsOf: url)))
        } else {
            guard allowingLocalPaths else { throw ImageError.unsupported }
            imported = .path(url.path)
        }
        try Task.checkCancellation()
        return imported
    }

    private enum ImageError: LocalizedError {
        case unsupported, unreadable
        var errorDescription: String? {
            switch self {
            case .unsupported: "Only images can be attached."
            case .unreadable: "This file cannot be decoded as an image. Attach a readable image file."
            }
        }
    }
}

public func joinedComposerText(_ existing: String, _ incoming: String) -> String {
    [existing, incoming].filter { !$0.isEmpty }.joined(separator: "\n\n")
}

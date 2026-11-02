import ChannelKit
import CoreGraphics
import Foundation
import Observation
import OSLog

@MainActor @Observable
public final class ChannelArtifactSession {
    public private(set) var artifact: ChannelArtifact?
    public private(set) var pages: ArtifactPageList?
    public private(set) var content: ArtifactContent?
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public var actionError: String?
    public private(set) var direction = 0
    public private(set) var thumbnails: [String: CGImage] = [:]
    public private(set) var channelID: String?
    @ObservationIgnored private var api: ChannelAPI?
    @ObservationIgnored private var available: [ChannelArtifact] = []
    @ObservationIgnored private var extra: ChannelArtifact?
    @ObservationIgnored private var cached: [String: ArtifactContent] = [:]
    @ObservationIgnored private var preparedFiles: [String: URL] = [:]
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var thumbnailToken = UUID()
    @ObservationIgnored private var thumbnailFailures: Set<String> = []
    @ObservationIgnored private let decodeImage: ArtifactContent.ImageDecoder
    @ObservationIgnored private let download: ArtifactContent.Download

    public init(decodeImage: @escaping ArtifactContent.ImageDecoder,
                download: @escaping ArtifactContent.Download = ArtifactDownload.file) {
        self.decodeImage = decodeImage
        self.download = download
    }

    public var server: URL? { api?.baseURL }
    public var isPresented: Bool { artifact != nil }
    public var isUnavailable: Bool { artifact != nil && pages?.selected == nil }
    public var resource: URL? { artifact?.url.flatMap { api?.resourceURL($0) } }
    public var kind: ArtifactContentKind { artifact.map(ArtifactContentKind.init) ?? .file }
    public var subtitle: String {
        guard let artifact else { return "" }
        let type = kind.label(for: artifact)
        guard let pages, pages.artifacts.count > 1, let index = pages.index else { return type }
        return "\(type) · \(index + 1) of \(pages.artifacts.count)"
    }

    /// Returns true when native adapters must also discard their old channel's rendering state.
    @discardableResult
    public func configure(api: ChannelAPI?, channelID: String, artifacts: [ChannelArtifact]) -> Bool {
        let changed = self.channelID != channelID || self.api?.baseURL != api?.baseURL
        if changed { close() }
        self.api = api
        self.channelID = channelID
        update(artifacts)
        return changed
    }

    public func update(_ artifacts: [ChannelArtifact]) {
        available = artifacts
        guard pages != nil else { return }
        if let extra, artifacts.contains(where: { $0.id == extra.id }) { self.extra = nil }
        var listed = artifacts
        if let extra { listed.append(extra) }
        pages?.update(listed)
        if let selected = pages?.selected { artifact = selected }
        else {
            loadTask?.cancel()
            content = nil
            isLoading = false
        }
        prepareThumbnails()
    }

    public func open(_ artifact: ChannelArtifact) {
        extra = available.contains(where: { $0.id == artifact.id }) ? nil : artifact
        pages = ArtifactPageList(artifacts: available, opening: artifact)
        direction = 0
        self.artifact = artifact
        load()
        prepareThumbnails()
    }

    @discardableResult
    public func select(_ id: String) -> Bool {
        guard id != artifact?.id else { return false }
        let previous = pages?.index ?? 0
        guard pages?.select(id) == true, let selected = pages?.selected else { return false }
        direction = (pages?.index ?? previous) > previous ? 1 : -1
        artifact = selected
        load()
        return true
    }

    public func move(by offset: Int) {
        guard let index = pages?.index, let pages, pages.artifacts.indices.contains(index + offset) else { return }
        select(pages.artifacts[index + offset].id)
    }

    public func close() {
        loadTask?.cancel()
        thumbnailTask?.cancel()
        loadTask = nil
        thumbnailTask = nil
        token = UUID()
        thumbnailToken = UUID()
        artifact = nil
        pages = nil
        content = nil
        cached = [:]
        thumbnails = [:]
        preparedFiles = [:]
        thumbnailFailures = []
        loadError = nil
        actionError = nil
        isLoading = false
    }

    public func reload() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailToken = UUID()
        if let artifact {
            thumbnails[artifact.id] = nil
            thumbnailFailures.remove(artifact.id)
        }
        load(reloading: true)
    }

    private func load(reloading: Bool = false) {
        loadTask?.cancel()
        if !reloading { content = nil }
        token = UUID()
        loadError = nil
        actionError = nil
        guard let artifact else { return }
        if !reloading, let cached = cached[artifact.id] {
            content = cached
            isLoading = false
            return
        }
        guard let api else { loadError = "The Toy Box server is unavailable."; return }
        isLoading = true
        let token = token
        loadTask = Task { [weak self, decodeImage, download] in
            do {
                let loaded = try await ArtifactContent.load(
                    artifact, api: api, preparedFile: reloading ? nil : self?.preparedFiles[artifact.id],
                    decodeImage: decodeImage, download: download)
                try Task.checkCancellation()
                guard let self, self.token == token, !isUnavailable else { return }
                cached[artifact.id] = loaded
                preparedFiles[artifact.id] = loaded.file
                content = loaded
                isLoading = false
                prepareThumbnails()
            } catch is CancellationError {
            } catch {
                guard let self, self.token == token, !Task.isCancelled else { return }
                isLoading = false
                if content != nil { actionError = error.localizedDescription }
                else { loadError = error.localizedDescription }
            }
        }
    }

    private func prepareThumbnails() {
        guard thumbnailTask == nil, let pages, let api else { return }
        let start = max(0, min((pages.index ?? 0) - 4, pages.artifacts.count - 9))
        let candidates = pages.artifacts.dropFirst(start).prefix(9).filter {
            let kind = ArtifactContentKind($0)
            return (kind == .image || kind == .svg) && thumbnails[$0.id] == nil
                && !thumbnailFailures.contains($0.id)
                && ($0.id != artifact?.id || content != nil)
        }
        guard !candidates.isEmpty else { return }
        thumbnailToken = UUID()
        let token = thumbnailToken
        thumbnailTask = Task { [weak self, decodeImage, download] in
            for candidate in candidates {
                do {
                    guard let self, token == thumbnailToken else { return }
                    let file: URL
                    if let prepared = cached[candidate.id]?.file ?? preparedFiles[candidate.id] { file = prepared }
                    else {
                        guard let resource = candidate.url.flatMap(api.resourceURL) else {
                            throw ChannelAPIError.invalidMessage("The artifact thumbnail has no usable resource URL.")
                        }
                        file = try await download(candidate, resource)
                    }
                    let decoded = try await decodeImage(file, ArtifactContentKind(candidate), 64)
                    try Task.checkCancellation()
                    guard token == thumbnailToken else { return }
                    preparedFiles[candidate.id] = file
                    thumbnails[candidate.id] = decoded.image
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.thumbnailFailures.insert(candidate.id)
                    Logger(subsystem: "dev.toybox", category: "Artifacts")
                        .error("Artifact thumbnail failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let self, token == thumbnailToken else { return }
            thumbnailTask = nil
            prepareThumbnails()
        }
    }
}

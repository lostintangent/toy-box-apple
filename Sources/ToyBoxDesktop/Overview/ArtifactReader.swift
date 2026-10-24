import AppKit
import ChannelClient
import ChannelKit
import Observation
import UniformTypeIdentifiers
import WebKit

@MainActor @Observable
final class ArtifactOpener {
    private(set) var artifact: ChannelArtifact?
    private(set) var pages: ArtifactPageList?
    private(set) var content: ArtifactContent?
    private(set) var image: NSImage?
    private(set) var isLoading = false
    private(set) var loadError: String?
    var actionError: String?
    var previewFile: URL?
    private(set) var direction = 0
    private(set) var animates = true
    @ObservationIgnored private var api: ChannelAPI?
    @ObservationIgnored private var channelID: String?
    @ObservationIgnored private var available: [ChannelArtifact] = []
    @ObservationIgnored private var extra: ChannelArtifact?
    @ObservationIgnored private var cached: [String: ArtifactContent] = [:]
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private weak var interaction: ChannelInteraction?
    @ObservationIgnored private weak var imageViewer: ImageViewer?
    @ObservationIgnored private weak var invokingResponder: NSResponder?
    @ObservationIgnored private weak var invokingWindow: NSWindow?
    @ObservationIgnored var webView: WKWebView?
    @ObservationIgnored var scrollOffsets: [String: CGFloat] = [:]

    var isPresented: Bool { artifact != nil }
    var isUnavailable: Bool { artifact != nil && pages?.selected == nil }
    var resource: URL? { artifact?.url.flatMap { api?.resourceURL($0) } }
    var kind: ArtifactContentKind { artifact.map(ArtifactContentKind.init) ?? .file }
    var subtitle: String {
        guard let artifact else { return "" }
        let type = kind.label(for: artifact)
        guard let pages, pages.artifacts.count > 1, let index = pages.index else { return type }
        return "\(type) · \(index + 1) of \(pages.artifacts.count)"
    }

    func configure(api: ChannelAPI?, channelID: String, artifacts: [ChannelArtifact],
                   interaction: ChannelInteraction, imageViewer: ImageViewer) {
        if self.channelID != channelID || self.api?.baseURL != api?.baseURL { close(animated: false) }
        self.api = api
        self.channelID = channelID
        self.interaction = interaction
        self.imageViewer = imageViewer
        update(artifacts)
    }

    func update(_ artifacts: [ChannelArtifact]) {
        available = artifacts
        guard pages != nil else { return }
        if let extra, artifacts.contains(where: { $0.id == extra.id }) { self.extra = nil }
        var listed = artifacts
        if let extra { listed.append(extra) }
        pages?.update(listed)
        if let selected = pages?.selected { artifact = selected }
        else {
            loadTask?.cancel()
            webView?.stopLoading()
            content = nil
            image = nil
            isLoading = false
        }
    }

    func open(_ artifact: ChannelArtifact) {
        animates = true
        invokingWindow = NSApp?.keyWindow
        invokingResponder = NSApp?.keyWindow?.firstResponder
        imageViewer?.close(animated: false)
        extra = available.contains(where: { $0.id == artifact.id }) ? nil : artifact
        pages = ArtifactPageList(artifacts: available, opening: artifact)
        direction = 0
        self.artifact = artifact
        interaction?.isArtifactViewerPresented = true
        load()
    }

    func select(_ id: String) {
        guard id != artifact?.id else { return }
        guard let previous = pages?.index, pages?.select(id) == true, let selected = pages?.selected else { return }
        direction = (pages?.index ?? previous) > previous ? 1 : -1
        artifact = selected
        load()
    }

    func move(by offset: Int) {
        guard let index = pages?.index, let pages, pages.artifacts.indices.contains(index + offset) else { return }
        select(pages.artifacts[index + offset].id)
    }

    func close(animated: Bool = true) {
        animates = animated
        loadTask?.cancel()
        token = UUID()
        webView?.stopLoading()
        webView = nil
        artifact = nil
        pages = nil
        content = nil
        image = nil
        cached = [:]
        images = [:]
        scrollOffsets = [:]
        loadError = nil
        actionError = nil
        previewFile = nil
        isLoading = false
        interaction?.isArtifactViewerPresented = false
        if animated, let window = invokingWindow, let responder = invokingResponder {
            Task { @MainActor [weak self, weak window, weak responder] in
                try? await Task.sleep(for: .milliseconds(220))
                guard self?.artifact == nil, let window, let responder else { return }
                if let view = responder as? NSView, view.window !== window { return }
                window.makeFirstResponder(responder)
            }
        }
    }

    func reload() { load(reloading: true) }
    func thumbnail(for artifact: ChannelArtifact) -> NSImage? { images[artifact.id] }

    func copyLink() {
        guard let resource else { actionError = "The artifact's link is unavailable."; return }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(resource.absoluteString, forType: .string) {
            actionError = "The artifact's link could not be copied."
        }
    }

    func openFile() {
        guard let file = content?.file else { actionError = "Load the artifact before opening its file."; return }
        if !NSWorkspace.shared.open(file) { actionError = "The file could not be opened by its default application." }
    }

    func openInToyBox(app: AppModel) {
        guard let artifact, let channelID, let url = app.channelURL(channelID: channelID, files: [artifact.file]) else {
            actionError = "The channel's Toy Box editor link is unavailable."
            return
        }
        if !NSWorkspace.shared.open(url) { actionError = "The Toy Box editor could not be opened." }
    }

    var canPageUsingKeys: Bool {
        guard let responder = NSApp?.keyWindow?.firstResponder else { return true }
        if responder is NSTextView { return false }
        if let view = responder as? NSView, let webView, view.isDescendant(of: webView) { return false }
        return true
    }

    private func load(reloading: Bool = false) {
        loadTask?.cancel()
        if !reloading {
            webView?.stopLoading()
            webView = nil
            image = nil
            content = nil
        }
        token = UUID()
        loadError = nil
        actionError = nil
        guard let artifact else { return }
        if !reloading, let cached = cached[artifact.id] {
            content = cached
            image = images[artifact.id]
            isLoading = false
            return
        }
        guard let api else { loadError = "The Toy Box server is unavailable."; return }
        isLoading = true
        let token = token
        loadTask = Task { [weak self] in
            do {
                let loaded = try await ArtifactContent.load(artifact, api: api)
                let bitmap = loaded.kind == .image
                    ? try await Task.detached(priority: .userInitiated) { try ImageViewer.decode(loaded.file) }.value : nil
                try Task.checkCancellation()
                guard let self, self.token == token else { return }
                cached[artifact.id] = loaded
                content = loaded
                if let bitmap {
                    let decoded = NSImage(cgImage: bitmap, size: .zero)
                    images[artifact.id] = decoded
                    image = decoded
                }
                isLoading = false
            } catch is CancellationError {
            } catch {
                guard let self, self.token == token, !Task.isCancelled else { return }
                isLoading = false
                if content != nil { actionError = error.localizedDescription }
                else { loadError = error.localizedDescription }
            }
        }
    }
}

extension ArtifactContentKind {
    func label(for artifact: ChannelArtifact) -> String {
        switch self {
        case .markdown: "Markdown"
        case .html: "HTML"
        case .svg: "SVG"
        case .image, .file:
            UTType(filenameExtension: (artifact.file.path as NSString).pathExtension)?.localizedDescription ?? "Document"
        }
    }
}

/// Fetches artifact content from the server's resource URL, never assuming the file is local.
enum ArtifactDownload {
    static func text(from resource: URL) async throws -> String {
        let request = URLRequest(url: resource, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChannelAPIError.invalidMessage("This Markdown artifact is not valid UTF-8 text.")
        }
        return text
    }

    static func file(for artifact: ChannelArtifact, from resource: URL) async throws -> URL {
        let request = URLRequest(url: resource, cachePolicy: .reloadIgnoringLocalCacheData)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try validate(response)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToyBoxDesktop-Artifacts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = (artifact.file.path as NSString).lastPathComponent
        let destination = directory.appendingPathComponent(
            ["", ".", "..", "/"].contains(basename) ? "Artifact" : basename)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ChannelAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ChannelAPIError.http(status: http.statusCode, message: "The artifact could not be loaded.")
        }
    }
}

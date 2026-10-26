import AppKit
import ChannelClient
import ChannelKit
import Observation
import ToyBoxUI
import WebKit

@MainActor @Observable
final class ArtifactOpener {
    let session = ChannelArtifactSession(decodeImage: ArtifactImageDecoder.decode)
    var previewFile: URL?
    private(set) var animates = true
    var imageZoomRevision = 0
    @ObservationIgnored private var renderedImage: (bitmap: CGImage, image: NSImage)?
    @ObservationIgnored private var renderedThumbnails: [String: (bitmap: CGImage, image: NSImage)] = [:]
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private weak var interaction: ChannelInteraction?
    @ObservationIgnored private weak var imageViewer: ImageViewer?
    @ObservationIgnored private weak var invokingResponder: NSResponder?
    @ObservationIgnored private weak var invokingWindow: NSWindow?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored weak var nativeImageView: ArtifactImageScrollView?
    @ObservationIgnored var webView: WKWebView?
    @ObservationIgnored weak var webRenderer: ArtifactWebContent?
    @ObservationIgnored var webReadingStates: [String: ArtifactWebReadingState] = [:]
    @ObservationIgnored var scrollOffsets: [String: CGFloat] = [:]

    var artifact: ChannelArtifact? { session.artifact }
    var pages: ArtifactPageList? { session.pages }
    var content: ArtifactContent? { session.content }
    var isLoading: Bool { session.isLoading }
    var loadError: String? { session.loadError }
    var actionError: String? {
        get { session.actionError }
        set { session.actionError = newValue }
    }
    var direction: Int { session.direction }
    var isPresented: Bool { session.isPresented }
    var isUnavailable: Bool { session.isUnavailable }
    var resource: URL? { session.resource }
    var kind: ArtifactContentKind { session.kind }
    var subtitle: String { session.subtitle }
    var image: NSImage? {
        guard let content, let bitmap = content.bitmap else { return nil }
        if let renderedImage, renderedImage.bitmap === bitmap { return renderedImage.image }
        let image = NSImage(cgImage: bitmap, size: content.imageSize ?? .zero)
        renderedImage = (bitmap, image)
        return image
    }

    func configure(api: ChannelAPI?, channelID: String, artifacts: [ChannelArtifact],
                   interaction: ChannelInteraction, imageViewer: ImageViewer) {
        if session.configure(api: api, channelID: channelID, artifacts: artifacts) {
            finishClosing(animated: false)
        }
        self.interaction = interaction
        self.imageViewer = imageViewer
        if session.isUnavailable { stopWebRenderer() }
    }

    func update(_ artifacts: [ChannelArtifact]) {
        session.update(artifacts)
        if session.isUnavailable { stopWebRenderer() }
    }

    func open(_ artifact: ChannelArtifact) {
        rememberWebReadingState()
        animates = true
        invokingWindow = window ?? NSApp?.keyWindow
        invokingResponder = invokingWindow?.firstResponder
        if let event = NSApp?.currentEvent, event.window === invokingWindow,
           let contentView = invokingWindow?.contentView,
           let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)) {
            var view: NSView? = hit
            while let candidate = view {
                if candidate is NSControl, candidate.acceptsFirstResponder {
                    invokingResponder = candidate
                    break
                }
                view = candidate.superview
            }
        }
        imageViewer?.close(animated: false)
        stopWebRenderer()
        session.open(artifact)
        interaction?.isArtifactViewerPresented = true
    }

    func select(_ id: String) {
        guard id != artifact?.id else { return }
        rememberWebReadingState()
        if session.select(id) { stopWebRenderer() }
    }

    func move(by offset: Int) {
        guard let index = pages?.index, let pages, pages.artifacts.indices.contains(index + offset) else { return }
        select(pages.artifacts[index + offset].id)
    }

    func close(animated: Bool = true) {
        session.close()
        finishClosing(animated: animated)
    }

    private func finishClosing(animated: Bool) {
        animates = animated
        token = UUID()
        stopWebRenderer()
        for state in webReadingStates.values { state.position.cancel() }
        webReadingStates = [:]
        renderedImage = nil
        renderedThumbnails = [:]
        nativeImageView?.stop()
        nativeImageView = nil
        scrollOffsets = [:]
        previewFile = nil
        interaction?.isArtifactViewerPresented = false
        let restoreToken = token
        if animated, let window = invokingWindow, let responder = invokingResponder {
            Task { @MainActor [weak self, weak window, weak responder] in
                do { try await Task.sleep(for: .milliseconds(220)) }
                catch is CancellationError { return }
                catch { self?.actionError = error.localizedDescription; return }
                guard self?.artifact == nil, self?.token == restoreToken, let window, let responder else { return }
                if let view = responder as? NSView, view.window !== window { return }
                window.makeFirstResponder(responder)
            }
        }
    }

    func reload() {
        if let artifact {
            webReadingStates[artifact.id]?.position.cancel()
            webReadingStates[artifact.id] = nil
        }
        session.reload()
    }

    func thumbnail(for artifact: ChannelArtifact) -> NSImage? {
        guard let bitmap = session.thumbnails[artifact.id] else { return nil }
        if let rendered = renderedThumbnails[artifact.id], rendered.bitmap === bitmap { return rendered.image }
        let image = NSImage(cgImage: bitmap, size: .zero)
        renderedThumbnails[artifact.id] = (bitmap, image)
        return image
    }

    var zoomActions: ImageZoomActions? {
        _ = imageZoomRevision
        guard let view = nativeImageView, content?.file == view.file else { return nil }
        return ImageZoomActions(canZoomIn: view.magnification < view.maxMagnification,
                                canZoomOut: view.magnification > view.minMagnification,
                                isActualSize: abs(view.magnification * view.fitScale - 1) < 0.01,
                                zoomIn: { view.zoom(by: 1.5) }, zoomOut: { view.zoom(by: 1 / 1.5) },
                                actualSize: { view.zoom(to: 1 / view.fitScale) })
    }

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
        guard let artifact, let channelID = session.channelID,
              let url = app.channelURL(channelID: channelID, files: [artifact.file]) else {
            actionError = "The channel's Toy Box editor link is unavailable."
            return
        }
        if !NSWorkspace.shared.open(url) { actionError = "The Toy Box editor could not be opened." }
    }

    var canPageUsingKeys: Bool {
        guard let responder = (webView?.window ?? window ?? NSApp?.keyWindow)?.firstResponder else { return true }
        if responder is NSTextView { return false }
        if let view = responder as? NSView, let webView, view.isDescendant(of: webView) { return false }
        return true
    }

    private func stopWebRenderer() {
        webView?.stopLoading()
        webView = nil
        webRenderer = nil
    }

    private func rememberWebReadingState() {
        guard let artifact, let state = webRenderer?.readingState else { return }
        webReadingStates[artifact.id]?.position.cancel()
        webReadingStates[artifact.id] = state
    }
}

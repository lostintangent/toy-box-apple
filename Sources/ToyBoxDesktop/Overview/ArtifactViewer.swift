import AppKit
import ChannelClient
import ChannelKit
import QuickLook
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers
import WebKit

struct ArtifactViewerCanvas: View {
    let store: ChannelStore
    @Environment(AppModel.self) private var app
    @Environment(ArtifactOpener.self) private var opener
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ImageViewer.self) private var images

    var body: some View {
        ZStack {
            if let artifact = opener.artifact {
                ArtifactViewerStage(opener: opener, artifact: artifact)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(opener.isPresented)
        .animation(opener.animates ? .easeInOut(duration: 0.2) : nil, value: opener.isPresented)
        .onChange(of: ObjectIdentifier(store), initial: true) {
            opener.configure(api: app.api, channelID: store.id, artifacts: store.artifacts,
                             interaction: interaction, imageViewer: images)
        }
        .onChange(of: store.artifacts) { _, artifacts in opener.update(artifacts) }
        .onChange(of: store.phase == .deleted) { _, deleted in
            if deleted { opener.close(animated: false) }
        }
        .onChange(of: images.session?.id) { _, id in
            if id != nil { opener.close(animated: false) }
        }
        .onChange(of: opener.isPresented) { _, presented in
            interaction.isArtifactViewerPresented = presented
        }
    }
}

struct ArtifactViewerStage: View {
    @Bindable var opener: ArtifactOpener
    let artifact: ChannelArtifact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @ViewState private var showsSpinner = false

    private var hasStrip: Bool { (opener.pages?.artifacts.count ?? 0) > 1 }
    private var background: Color {
        Color(nsColor: opener.kind == .markdown ? .textBackgroundColor : .underPageBackgroundColor)
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            page
                .id(artifact.id)
                .transition(pageTransition)
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            if let error = opener.actionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Dismiss", systemImage: "xmark") { opener.actionError = nil }
                        .labelStyle(.iconOnly)
                }
                .font(.callout)
                .padding(12)
                .background(.background)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if hasStrip {
                ArtifactNavigationCapsule(opener: opener)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: artifact.id) { focused = true }
        .onExitCommand { opener.close() }
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            // Physical arrow flags and Caps Lock are not shortcut modifiers.
            guard press.modifiers.subtracting([.numericPad, .function, .capsLock]).isEmpty,
                  opener.canPageUsingKeys else { return .ignored }
            opener.move(by: press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        .animation(.easeInOut(duration: 0.2), value: artifact.id)
        .task(id: opener.isLoading) {
            showsSpinner = false
            guard opener.isLoading else { return }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch is CancellationError { return }
            catch { opener.actionError = error.localizedDescription; return }
            if !Task.isCancelled { showsSpinner = true }
        }
        .quickLookPreview($opener.previewFile)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("\(artifact.title), \(opener.subtitle)")
        .accessibilityAction(.escape) { opener.close() }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset = CGFloat(opener.direction) * 40
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: offset)),
                           removal: .opacity.combined(with: .offset(x: -offset)))
    }

    @ViewBuilder private var page: some View {
        if opener.isUnavailable {
            ContentUnavailableView("Artifact Unavailable", systemImage: "doc.badge.ellipsis",
                                   description: Text("This artifact is no longer available."))
        } else if let error = opener.loadError {
            ContentUnavailableView {
                Label("Couldn't Load Artifact", systemImage: "doc.badge.ellipsis")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { opener.reload() }
            }
        } else if let content = opener.content {
            switch content.kind {
            case .markdown:
                ArtifactMarkdownPage(content: content, opener: opener, bottomInset: hasStrip ? 0 : 24)
            case .html:
                ArtifactWebPage(content: content, opener: opener, bottomInset: hasStrip ? 0 : 24)
            case .image, .svg:
                if let image = opener.image {
                    ArtifactNativeImage(content: content, image: image, opener: opener)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, hasStrip ? 0 : 24)
                }
            case .file:
                unsupported
            }
        } else {
            Group {
                if showsSpinner { ProgressView("Loading artifact…").controlSize(.small) }
                else { Color.clear }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var unsupported: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(for: artifact.fileType))
                .resizable().frame(width: 64, height: 64).accessibilityHidden(true)
            Text(artifact.title).font(.headline)
            Text("Preview this file, or open it in its default application.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Quick Look", systemImage: "eye") { opener.previewFile = opener.content?.file }
                Button("Open in Default Application", systemImage: "arrow.up.forward.app") { opener.openFile() }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ArtifactMarkdownPage: View {
    let content: ArtifactContent
    let opener: ArtifactOpener
    let bottomInset: CGFloat
    @ViewState private var position: ScrollPosition

    init(content: ArtifactContent, opener: ArtifactOpener, bottomInset: CGFloat) {
        self.content = content
        self.opener = opener
        self.bottomInset = bottomInset
        _position = ViewState(initialValue: ScrollPosition(y: opener.scrollOffsets[content.artifact.id] ?? 0))
    }

    var body: some View {
        ScrollView {
            Group {
                if let text = content.text {
                    TranscriptMarkdown(content: text, agents: [], baseURL: content.resource,
                                       bodySize: 15, codeSize: 13, lineSpacing: 4)
                } else {
                    ContentUnavailableView("Couldn't Load Artifact", systemImage: "doc.badge.ellipsis",
                                           description: Text("The artifact's text is unavailable."))
                }
            }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
            opener.scrollOffsets[content.artifact.id] = offset
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
}

private struct ArtifactWebPage: View {
    let content: ArtifactContent
    let opener: ArtifactOpener
    let bottomInset: CGFloat
    @ViewState private var renderer: ArtifactWebContent
    @ViewState private var showsSpinner = false

    init(content: ArtifactContent, opener: ArtifactOpener, bottomInset: CGFloat) {
        self.content = content
        self.opener = opener
        self.bottomInset = bottomInset
        _renderer = ViewState(initialValue: ArtifactWebContent())
    }

    var body: some View {
        ZStack {
            if content.text != nil {
                GeometryReader { geometry in
                    ArtifactWebView(renderer: renderer, obscuredInsets: geometry.safeAreaInsets,
                                    bottomInset: bottomInset)
                        .ignoresSafeArea(edges: .vertical)
                }
                .scrollEdgeEffectStyle(.hard, for: .top)
            } else {
                ContentUnavailableView("Couldn't Load Artifact", systemImage: "doc.badge.ellipsis",
                                       description: Text("The artifact's text is unavailable."))
            }
            if showsSpinner { ProgressView("Loading artifact…").controlSize(.small) }
            if let error = renderer.error {
                ContentUnavailableView {
                    Label("Couldn't Load Artifact", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { opener.reload() }
                }
                .background(.background)
            }
        }
        .task(id: content.file) {
            guard let text = content.text else { return }
            opener.webView = renderer.webView
            opener.webRenderer = renderer
            await renderer.load(text, directory: content.directory,
                                server: content.server, resource: content.resource,
                                state: opener.webReadingStates[content.artifact.id])
        }
        .task(id: renderer.isLoading) {
            showsSpinner = false
            guard renderer.isLoading else { return }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch is CancellationError { return }
            catch { opener.actionError = error.localizedDescription; return }
            if !Task.isCancelled { showsSpinner = true }
        }
        .onDisappear {
            renderer.stop()
            if opener.webView === renderer.webView { opener.webView = nil }
            if opener.webRenderer === renderer { opener.webRenderer = nil }
        }
    }
}

private struct ArtifactWebView: NSViewRepresentable {
    let renderer: ArtifactWebContent
    let obscuredInsets: EdgeInsets
    let bottomInset: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        renderer.webView.allowsMagnification = true
        renderer.webView.underPageBackgroundColor = .clear
        updateInsets(renderer.webView)
        return renderer.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        updateInsets(nsView)
    }

    private func updateInsets(_ webView: WKWebView) {
        let next = NSEdgeInsets(top: obscuredInsets.top, left: 0,
                               bottom: obscuredInsets.bottom + bottomInset, right: 0)
        let current = webView.obscuredContentInsets
        if current.top != next.top || current.bottom != next.bottom || current.left != 0 || current.right != 0 {
            webView.obscuredContentInsets = next
        }
    }
}

private struct ArtifactNativeImage: NSViewRepresentable {
    let content: ArtifactContent
    let image: NSImage
    let opener: ArtifactOpener

    func makeNSView(context: Context) -> ArtifactImageScrollView {
        let view = ArtifactImageScrollView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ArtifactImageScrollView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: ArtifactImageScrollView) {
        view.onZoomChange = { [weak opener] in opener?.imageZoomRevision += 1 }
        view.onError = { [weak opener] in opener?.actionError = $0 }
        view.configure(image: image, file: content.file, isSVG: content.kind == .svg)
        opener.nativeImageView = view
    }

    static func dismantleNSView(_ nsView: ArtifactImageScrollView, coordinator: ()) {
        nsView.stop()
    }
}

final class ArtifactImageScrollView: NSScrollView {
    let imageView = NSImageView()
    private(set) var file: URL?
    var onZoomChange: (() -> Void)?
    var onError: ((String) -> Void)?
    private var isSVG = false
    private var renderedEdge = 0
    private var rasterTask: Task<Void, Never>?

    var fitScale: CGFloat {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return 1 }
        return min(1, contentSize.width / size.width, contentSize.height / size.height)
    }

    override var magnification: CGFloat {
        didSet {
            onZoomChange?()
            rerasterizeIfNeeded()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 8
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        documentView = imageView
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if magnification == 1 {
            imageView.setFrameSize(contentSize)
            maxMagnification = max(8, 1 / max(fitScale, 0.0001))
        }
    }

    func configure(image: NSImage, file: URL, isSVG: Bool) {
        guard self.file != file else { return }
        stop()
        self.file = file
        self.isSVG = isSVG
        imageView.image = image
        renderedEdge = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        magnification = 1
        needsLayout = true
    }

    func zoom(by factor: CGFloat) { zoom(to: magnification * factor) }

    func zoom(to value: CGFloat) {
        setMagnification(min(maxMagnification, max(minMagnification, value)),
                         centeredAt: CGPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY))
        onZoomChange?()
        rerasterizeIfNeeded()
    }

    func stop() { rasterTask?.cancel(); rasterTask = nil }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onZoomChange?()
        rerasterizeIfNeeded()
    }

    private func rerasterizeIfNeeded() {
        guard isSVG, let file, let size = imageView.image?.size else { return }
        let edge = Int(min(8192, ceil(max(size.width, size.height) * fitScale * magnification
                                     * (window?.backingScaleFactor ?? 2))))
        guard edge > renderedEdge else { return }
        rasterTask?.cancel()
        rasterTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                let bitmap = try await Task.detached(priority: .userInitiated) {
                    try TranscriptSVGImage.decode(file, maximumPixelSize: edge).image
                }.value
                try Task.checkCancellation()
                guard let self, self.file == file else { return }
                imageView.image = NSImage(cgImage: bitmap, size: size)
                renderedEdge = edge
            } catch is CancellationError {
            } catch {
                self?.onError?("The drawing is still visible, but its zoom detail could not be refreshed. \(error.localizedDescription)")
            }
        }
    }
}

private struct ArtifactNavigationCapsule: View {
    let opener: ArtifactOpener

    var body: some View {
        if let pages = opener.pages {
            let count = pages.artifacts.count
            let stripWidth = CGFloat(min(count, 9)) * 32 + CGFloat(max(0, min(count, 9) - 1)) * 6
            HStack(spacing: 12) {
                arrow("chevron.backward", title: "Previous Artifact", enabled: pages.canShowPrevious) { opener.move(by: -1) }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(pages.artifacts.enumerated()), id: \.element.id) { index, artifact in
                                cell(artifact, index: index, count: count).id(artifact.id)
                            }
                        }
                        .padding(4)
                    }
                    .scrollIndicators(.never)
                    .scrollDisabled(count <= 9)
                    .frame(width: stripWidth + 8, height: 40)
                    .padding(-4)
                    .onAppear { proxy.scrollTo(pages.selectedID, anchor: .center) }
                    .onChange(of: pages.selectedID) { _, id in
                        withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                arrow("chevron.forward", title: "Next Artifact", enabled: pages.canShowNext) { opener.move(by: 1) }
            }
            .padding(8)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    private func arrow(_ symbol: String, title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private func cell(_ artifact: ChannelArtifact, index: Int, count: Int) -> some View {
        let selected = artifact.id == opener.artifact?.id
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button { opener.select(artifact.id) } label: {
            Image(nsImage: opener.thumbnail(for: artifact) ?? NSWorkspace.shared.icon(for: artifact.fileType))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .clipShape(shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(selected ? 1 : 0.7)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2).padding(-4)
            }
        }
        .help(artifact.title)
        .accessibilityLabel("\(artifact.title), \(selected ? "selected, " : "")\(index + 1) of \(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ArtifactViewerToolbar: ToolbarContent {
    let opener: ArtifactOpener
    let store: ChannelStore
    let app: AppModel
    let interaction: ChannelInteraction

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back to Conversation", systemImage: "chevron.backward") { opener.close() }
                .help("Back to Conversation")
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let resource = opener.resource {
                ShareLink(item: resource) { Label("Share", systemImage: "square.and.arrow.up") }
                    .help("Share")
            } else {
                Button("Share", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
            }
            Menu {
                Button("Open in Toy Box", systemImage: "arrow.up.forward.app") { opener.openInToyBox(app: app) }
                Button("Reload", systemImage: "arrow.clockwise") { opener.reload() }
                    .disabled(opener.isUnavailable)
                Button("Copy Link", systemImage: "link") { opener.copyLink() }.disabled(opener.resource == nil)
                Divider()
                Button("Quick Look", systemImage: "eye") { opener.previewFile = opener.content?.file }
                    .disabled(opener.content == nil)
                Button("Open in Default Application", systemImage: "arrow.up.forward.app") { opener.openFile() }
                    .disabled(opener.content == nil)
                if let artifact = opener.artifact, let share = store.artifactShares[artifact.file.id] {
                    Divider()
                    Button("Show in Transcript", systemImage: "bubble.left") {
                        opener.close()
                        interaction.reveal(sequence: share.sequence)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More")
        }
    }
}

private extension ChannelArtifact {
    var fileType: UTType { UTType(filenameExtension: (file.path as NSString).pathExtension) ?? .data }
}

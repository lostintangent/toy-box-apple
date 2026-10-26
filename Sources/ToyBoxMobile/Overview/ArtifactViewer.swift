import ChannelClient
import ChannelKit
import QuickLook
import SwiftUI
import ToyBoxUI
import UIKit
import WebKit

struct ArtifactViewer: View {
    let session: ChannelArtifactSession
    @Environment(AppModel.self) private var app
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @ViewState private var reading = ArtifactReaderState()
    @ViewState private var showsSpinner = false
    @AccessibilityFocusState private var titleFocused: Bool

    private var hasNavigation: Bool { (session.pages?.artifacts.count ?? 0) > 1 }
    private var bottomClearance: CGFloat { hasNavigation ? 88 : 24 }
    private var canPrepareOriginal: Bool {
        session.resource != nil && !session.isUnavailable && !session.isLoading && !reading.isPreparingOriginal
    }
    private var canZoom: Bool {
        _ = reading.imageRevision
        return reading.imageView != nil
    }
    private var source: ChannelArtifactShare? {
        guard let artifact = session.artifact, let store = app.selectedStore,
              store.id == session.channelID, store.api.baseURL == session.server else { return nil }
        return store.artifactShares[artifact.file.id]
    }

    var body: some View {
        ZStack {
            page
                .id(session.artifact?.id)
                .transition(pageTransition)
            if showsSpinner {
                ProgressView("Loading artifact...")
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) {
            if hasNavigation {
                navigation
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar { toolbar }
        .quickLookPreview($reading.preview)
        .sheet(item: $reading.sharing) { share in
            ArtifactShareSheet(file: share.file) { session.actionError = $0 }
        }
        .alert("Couldn't Complete Action", isPresented: Binding(
            get: { session.actionError != nil },
            set: { if !$0 { session.actionError = nil } }
        )) {
            Button("OK") { session.actionError = nil }
        } message: {
            Text(session.actionError ?? "").foregroundStyle(Color(uiColor: .label))
        }
        .task(id: session.isLoading) {
            showsSpinner = false
            guard session.isLoading else { return }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch is CancellationError { return }
            catch { session.actionError = error.localizedDescription; return }
            if !Task.isCancelled { showsSpinner = true }
        }
        .task(id: session.artifact?.id) { titleFocused = true }
        .onChange(of: session.artifact?.id) { _, _ in reading.cancelOriginal() }
        .onChange(of: session.isUnavailable) { _, unavailable in
            if unavailable { reading.cancelOriginal() }
        }
        .onChange(of: session.isPresented) { _, presented in
            if !presented { reading.reset() }
        }
        .onChange(of: ObjectIdentifier(session)) { _, _ in reading.reset() }
        .onChange(of: session.server) { _, _ in reading.reset() }
        .onChange(of: session.channelID) { _, _ in reading.reset() }
        .onDisappear { reading.stopPendingOriginal() }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion, session.direction != 0 else { return .opacity }
        let offset: CGFloat = session.direction > 0 ? 40 : -40
        return .asymmetric(insertion: .offset(x: offset).combined(with: .opacity),
                           removal: .offset(x: -offset).combined(with: .opacity))
    }

    @ViewBuilder
    private var page: some View {
        if session.isUnavailable {
            ContentUnavailableView("Artifact Unavailable", systemImage: "doc.badge.ellipsis",
                                   description: Text("This artifact is no longer available."))
        } else if let content = session.content {
            switch content.kind {
            case .markdown:
                ArtifactMarkdownDocument(content: content, reading: reading, bottomInset: bottomClearance)
            case .html:
                ArtifactHTMLDocument(content: content, reading: reading, bottomInset: bottomClearance)
            case .image, .svg:
                if let bitmap = content.bitmap {
                    ArtifactNativeImage(content: content, image: UIImage(cgImage: bitmap),
                                        title: session.artifact?.title ?? content.artifact.title, reading: reading,
                                        onError: { session.actionError = $0 })
                        .onAppear { reading.imageRevision += 1 }
                        .onDisappear { reading.imageRevision += 1 }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, bottomClearance)
                        .background(Color(uiColor: .secondarySystemBackground))
                } else {
                    failure("The artifact's image could not be decoded.")
                }
            case .file:
                unsupported(content)
            }
        } else if let error = session.loadError {
            failure(error)
        } else if session.artifact == nil {
            ContentUnavailableView("No Artifacts Yet", systemImage: "doc",
                                   description: Text("Files shared by this team will appear here."))
        }
    }

    private func failure(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load Artifact", systemImage: "doc.badge.ellipsis")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") { session.reload() }
        }
        .padding(.bottom, bottomClearance)
    }

    private func unsupported(_ content: ArtifactContent) -> some View {
        ContentUnavailableView {
            Label {
                Text("No Preview Available")
            } icon: {
                if let icon = UIDocumentInteractionController(url: content.file).icons.last {
                    Image(uiImage: icon).resizable().scaledToFit().frame(width: 64, height: 64)
                } else {
                    Image(systemName: "doc")
                }
            }
        } description: {
            Text("This \(content.kind.label(for: content.artifact)) file can be opened with Quick Look or shared to another app.")
        } actions: {
            Button("Quick Look", systemImage: "eye") { reading.prepareOriginal(session: session, sharing: false) }
                .disabled(!canPrepareOriginal)
            Button("Share Original", systemImage: "square.and.arrow.up") {
                reading.prepareOriginal(session: session, sharing: true)
            }
            .disabled(!canPrepareOriginal)
        }
        .padding(.bottom, bottomClearance)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Back to Conversation", systemImage: "chevron.backward") { session.close() }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.escape, modifiers: [])
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text(session.artifact?.title ?? "Artifacts")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.subtitle)
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(1)
            }
            .accessibilityShowsLargeContentViewer {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.artifact?.title ?? "Artifacts").font(.headline)
                    Text(session.subtitle).font(.subheadline)
                }
                .foregroundStyle(Color(uiColor: .label))
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($titleFocused)
        }
        ToolbarItemGroup(placement: sizeClass == .compact ? .bottomBar : .topBarTrailing) {
            Button("Share Original", systemImage: "square.and.arrow.up") {
                reading.prepareOriginal(session: session, sharing: true)
            }
            .labelStyle(.iconOnly)
            .disabled(!canPrepareOriginal)
            Menu {
                Button("Open in Toy Box", systemImage: "arrow.up.forward.app", action: openInToyBox)
                    .disabled(session.isUnavailable || session.artifact == nil)
                Button("Reload", systemImage: "arrow.clockwise") { reading.reload(session) }
                    .disabled(session.isUnavailable || session.isLoading)
                Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = session.resource }
                    .disabled(session.resource == nil)
                Button("Quick Look", systemImage: "eye") { reading.prepareOriginal(session: session, sharing: false) }
                    .disabled(!canPrepareOriginal)
                if session.kind == .image || session.kind == .svg {
                    Divider()
                    Button("Fit Image", systemImage: "arrow.down.right.and.arrow.up.left") { reading.imageView?.fit() }
                        .disabled(!canZoom)
                    Button("Actual Size", systemImage: "1.magnifyingglass") { reading.imageView?.actualSize() }
                        .disabled(!canZoom)
                }
                if let source {
                    Divider()
                    Button("Show in Conversation", systemImage: "bubble") {
                        session.close()
                        interaction.reveal(sequence: source.sequence)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Button { move(by: -1) } label: {
                Label("Previous Artifact", systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .disabled(session.pages?.canShowPrevious != true)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        if let pages = session.pages {
                            ForEach(Array(pages.artifacts.enumerated()), id: \.element.id) { index, artifact in
                                thumbnailButton(artifact, index: index, count: pages.artifacts.count)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: session.artifact?.id, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .frame(maxWidth: CGFloat(min(9, session.pages?.artifacts.count ?? 0)) * 50 - 6)
            Button { move(by: 1) } label: {
                Label("Next Artifact", systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .disabled(session.pages?.canShowNext != true)
        }
        .buttonStyle(.plain)
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Artifacts")
    }

    private func thumbnailButton(_ artifact: ChannelArtifact, index: Int, count: Int) -> some View {
        Button { select(artifact.id) } label: {
            thumbnail(artifact)
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 6))
                .overlay {
                    if artifact.id == session.artifact?.id {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 2)
                    }
                }
                .padding(2)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(artifact.title), \(index + 1) of \(count)")
        .accessibilityAddTraits(artifact.id == session.artifact?.id ? .isSelected : [])
        .id(artifact.id)
    }

    @ViewBuilder
    private func thumbnail(_ artifact: ChannelArtifact) -> some View {
        if let image = session.thumbnails[artifact.id] {
            Image(uiImage: UIImage(cgImage: image)).resizable().scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: ChannelArtifactSymbol.name(for: ArtifactContentKind(artifact)))
                .foregroundStyle(.primary)
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func move(by offset: Int) {
        withAnimation(.easeInOut(duration: 0.2)) { session.move(by: offset) }
    }

    private func select(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) { _ = session.select(id) }
    }

    private func openInToyBox() {
        guard let artifact = session.artifact, let channel = session.channelID,
              let api = app.api, api.baseURL == session.server,
              let url = api.channelURL(channelID: channel, files: [artifact.file]) else {
            session.actionError = "The Toy Box editor link is unavailable."
            return
        }
        openURL(url) { accepted in
            if !accepted { session.actionError = "The Toy Box editor could not be opened." }
        }
    }
}

private struct ArtifactMarkdownDocument: View {
    let content: ArtifactContent
    let reading: ArtifactReaderState
    let bottomInset: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var textScale = 1
    @ViewState private var position: ScrollPosition
    @ViewState private var offset: CGFloat = 0

    init(content: ArtifactContent, reading: ArtifactReaderState, bottomInset: CGFloat) {
        self.content = content
        self.reading = reading
        self.bottomInset = bottomInset
        _position = ViewState(initialValue: ScrollPosition(y: reading.markdownOffsets[content.artifact.id] ?? 0))
    }

    var body: some View {
        ScrollView {
            if let text = content.text {
                TranscriptMarkdown(content: text, baseURL: content.directory, bodySize: 17,
                                   codeSize: 15, lineSpacing: 3, textScale: textScale,
                                   copyCode: { UIPasteboard.general.string = $0 }, mentionInk: { _ in .accentColor })
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                    .padding(.top, 24)
                    .padding(.bottom, bottomInset)
            }
        }
        .scrollPosition($position)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, value in offset = value }
        .onDisappear { reading.markdownOffsets[content.artifact.id] = offset }
    }
}

private struct ArtifactHTMLDocument: View {
    let content: ArtifactContent
    let reading: ArtifactReaderState
    let bottomInset: CGFloat
    @ViewState private var renderer = ArtifactWebRenderer.phone()
    @ViewState private var showsSpinner = false
    @ViewState private var delayError: String?
    @ViewState private var retry = 0

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                ArtifactWebView(renderer: renderer, safeArea: geometry.safeAreaInsets, bottomInset: bottomInset)
                    .ignoresSafeArea(edges: .vertical)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            if showsSpinner { ProgressView("Loading artifact...") }
            if let error = renderer.error ?? delayError {
                ContentUnavailableView {
                    Label("Couldn't Load Artifact", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { retry += 1 }
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
        .task(id: LoadIdentity(file: content.file, retry: retry)) {
            reading.webRenderer = renderer
            await loadDocument()
        }
        .task(id: renderer.isLoading) {
            showsSpinner = false
            guard renderer.isLoading else { return }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch is CancellationError { return }
            catch { delayError = error.localizedDescription; return }
            if !Task.isCancelled { showsSpinner = true }
        }
        .onDisappear {
            if let state = renderer.readingState { reading.webReadingStates[content.artifact.id] = state }
            renderer.stop()
            if reading.webRenderer === renderer { reading.webRenderer = nil }
        }
    }

    private func loadDocument() async {
        delayError = nil
        guard let text = content.text else { return }
        await renderer.load(text, directory: content.directory, server: content.server, resource: content.resource,
                            state: reading.webReadingStates[content.artifact.id])
    }

    private struct LoadIdentity: Hashable {
        let file: URL
        let retry: Int
    }
}

private struct ArtifactWebView: UIViewRepresentable {
    let renderer: ArtifactWebRenderer
    let safeArea: EdgeInsets
    let bottomInset: CGFloat

    func makeUIView(context: Context) -> WKWebView {
        renderer.webView.scrollView.contentInsetAdjustmentBehavior = .never
        updateUIView(renderer.webView, context: context)
        return renderer.webView
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let next = UIEdgeInsets(top: safeArea.top, left: 0, bottom: safeArea.bottom + bottomInset, right: 0)
        if view.obscuredContentInsets != next { view.obscuredContentInsets = next }
    }
}

private struct ArtifactNativeImage: UIViewRepresentable {
    let content: ArtifactContent
    let image: UIImage
    let title: String
    let reading: ArtifactReaderState
    let onError: (String) -> Void

    func makeUIView(context: Context) -> ArtifactImageScrollView {
        let view = ArtifactImageScrollView()
        configure(view)
        return view
    }

    func updateUIView(_ view: ArtifactImageScrollView, context: Context) { configure(view) }

    private func configure(_ view: ArtifactImageScrollView) {
        view.onError = onError
        view.configure(image: image, size: content.imageSize ?? image.size, file: content.file, title: title)
        reading.imageView = view
    }

    static func dismantleUIView(_ view: ArtifactImageScrollView, coordinator: ()) { view.stop() }
}

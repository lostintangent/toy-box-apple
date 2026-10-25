import AppKit
import ChannelClient
import ChannelKit
import Network
import Synchronization
import Testing
import WebKit
@testable import ToyBoxDesktop

@MainActor
@Suite("Artifact viewer", .serialized)
struct ArtifactViewerTests {
    @Test func contentKindsKeepSVGBeforeTheGeneralImageFallback() {
        #expect(ArtifactContentKind(artifact("notes.MD")) == .markdown)
        #expect(ArtifactContentKind(artifact("page.htm")) == .html)
        #expect(ArtifactContentKind(artifact("drawing.svg")) == .svg)
        #expect(ArtifactContentKind(artifact("photo.png")) == .image)
        #expect(ArtifactContentKind(artifact("report.pdf")) == .file)
    }

    @Test func pagingUsesTheChannelsNewestFirstOrderingWithoutWrapping() {
        let old = artifact("old.md", shared: "2026-10-24T20:00:00Z")
        let latest = artifact("latest.html", shared: "2026-10-24T22:00:00Z")
        let middle = artifact("middle.svg", shared: "2026-10-24T21:00:00Z")
        var pages = ArtifactPageList(artifacts: [old, latest, middle], opening: middle)
        #expect(pages.artifacts.map(\.id) == [latest.id, middle.id, old.id])
        #expect(pages.index == 1)
        let showedLatest = pages.move(by: -1)
        #expect(showedLatest)
        #expect(pages.selected == latest)
        let wrappedToOldest = pages.move(by: -1)
        #expect(!wrappedToOldest)
        let showedOldest = pages.move(by: 2)
        #expect(showedOldest)
        #expect(pages.selected == old)
        #expect(!pages.canShowNext)
        let selectedMissing = pages.select("not-an-artifact")
        #expect(!selectedMissing)
        #expect(pages.selected == old)
        pages.update([latest, middle])
        #expect(pages.selected == nil)
    }

    @Test func aTaskArtifactCanOpenBeforeItAppearsInTheSharedList() {
        let task = artifact("task.md")
        let shared = artifact("shared.svg")
        let pages = ArtifactPageList(artifacts: [shared], opening: task)
        #expect(pages.artifacts == [task, shared])
        #expect(pages.selected == task)
    }

    @Test func arrivalsKeepTheSelectedIdentityAndRemovalDoesNotSubstituteANeighbor() async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let api = try ChannelAPI(baseURL: fixture.url("/"))
        let original = ChannelArtifact(file: .init(kind: "machine", path: "original.md"), title: "Original",
                                       sharedAt: "2026-10-24T22:00:00Z", url: "/api/serve/test/original.md")
        let neighbor = ChannelArtifact(file: .init(kind: "machine", path: "neighbor.md"), title: "Neighbor",
                                       sharedAt: "2026-10-24T21:00:00Z", url: "/api/serve/test/neighbor.md")
        let newer = ChannelArtifact(file: .init(kind: "machine", path: "new.md"), title: "New",
                                    sharedAt: "2026-10-24T23:00:00Z", url: "/api/serve/test/new.md")
        let opener = ArtifactOpener()
        let interaction = ChannelInteraction()
        opener.configure(api: api, channelID: "studio-demo", artifacts: [original, neighbor],
                         interaction: interaction, imageViewer: ImageViewer())
        opener.open(original)
        defer { opener.close(animated: false) }
        #expect(interaction.isArtifactViewerPresented)
        try await wait { !opener.isLoading }
        #expect(opener.content?.artifact.id == original.id)
        let loaded = opener.content?.file
        opener.update([original, neighbor, newer])
        #expect(opener.artifact?.id == original.id)
        #expect(opener.content?.file == loaded)
        #expect(opener.subtitle == "Markdown · 2 of 3")
        opener.update([neighbor, newer])
        #expect(opener.artifact?.id == original.id)
        #expect(opener.isUnavailable)
        #expect(opener.content == nil)
        opener.select(neighbor.id)
        try await wait { !opener.isLoading }
        #expect(opener.content?.artifact.id == neighbor.id)
        #expect(!opener.isUnavailable)
        opener.close(animated: false)
        #expect(!interaction.isArtifactViewerPresented)
        #expect(!opener.isPresented)
    }

    @Test func reloadFailureKeepsThePreviouslyLoadedDocumentAndReportsTheActionError() async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let api = try ChannelAPI(baseURL: fixture.url("/"))
        let document = ChannelArtifact(file: .init(kind: "machine", path: "plan.md"), title: "Plan",
                                       url: "/api/serve/test/plan.md")
        let opener = ArtifactOpener()
        let interaction = ChannelInteraction()
        opener.configure(api: api, channelID: "studio-demo", artifacts: [document],
                         interaction: interaction, imageViewer: ImageViewer())
        opener.open(document)
        defer { opener.close(animated: false) }
        try await wait { !opener.isLoading }
        let loaded = try #require(opener.content?.file)
        _ = fixture.failures.withLock { $0.insert("/api/serve/test/plan.md") }
        opener.reload()
        try await wait { !opener.isLoading }
        #expect(opener.content?.file == loaded)
        #expect(opener.loadError == nil)
        #expect(opener.actionError?.contains("500") == true)
        #expect(opener.artifact?.id == document.id)
    }

    @Test func anObsoleteResponseCannotReplaceTheNewlySelectedArtifact() async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let slowPath = "/api/serve/test/slow.md"
        _ = fixture.heldPaths.withLock { $0.insert(slowPath) }
        let slow = ChannelArtifact(file: .init(kind: "machine", path: "slow.md"), title: "Slow", url: slowPath)
        let next = ChannelArtifact(file: .init(kind: "machine", path: "next.md"), title: "Next",
                                   url: "/api/serve/test/next.md")
        let opener = ArtifactOpener()
        let interaction = ChannelInteraction()
        opener.configure(api: try ChannelAPI(baseURL: fixture.url("/")), channelID: "studio-demo",
                         artifacts: [slow, next], interaction: interaction, imageViewer: ImageViewer())
        opener.open(slow)
        defer { opener.close(animated: false) }
        try await wait { fixture.requests.withLock { $0.contains { $0.path == slowPath } } }
        opener.select(next.id)
        try await wait { !opener.isLoading }
        fixture.release(slowPath)
        #expect(opener.artifact?.id == next.id)
        #expect(opener.content?.artifact.id == next.id)
        #expect(opener.loadError == nil)
        #expect(opener.actionError == nil)
    }

    @Test func HTMLUsesAnOpaqueFrameAndCanLoadOnlyTheServersFileResources() async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let web = ArtifactWebContent(openURL: { _ in
            Issue.record("The fixture must not open a browser.")
            return false
        })
        defer { web.stop() }
        let probe = ArtifactWebProbe()
        probe.attach(to: web.webView)
        let directory = fixture.url("/api/serve/test/documents/")
        let api = fixture.url("/api/v1/channels").absoluteString
        let alias = fixture.url("/api/v1/channels", host: "localhost").absoluteString
        let fakeCookie = try #require(HTTPCookie(properties: [
            .name: "toybox-artifact-test-\(UUID().uuidString)", .value: "not-a-credential",
            .domain: "127.0.0.1", .path: "/api/serve/test/",
        ]))
        HTTPCookieStorage.shared.setCookie(fakeCookie)
        defer { HTTPCookieStorage.shared.deleteCookie(fakeCookie) }
        await web.load("""
            <!doctype html><html><head><base href="https://wrong.invalid/"></head><body>
            <script>
            (async () => {
                const result = {scripts:true, parentAccess:false, cookieReadable:false, base:document.baseURI};
                try { result.parentAccess = !!parent.document; } catch {}
                try { result.cookie = document.cookie; result.cookieReadable = true; } catch {}
                result.api = await fetch("\(api)", {credentials:"include"}).then(() => true, () => false);
                result.aliasAPI = await fetch("\(alias)").then(() => true, () => false);
                const image = new Image();
                const loaded = new Promise(resolve => { image.onload=()=>resolve(true); image.onerror=()=>resolve(false); });
                image.src = "pixel.svg";
                document.body.append(image);
                result.relativeImage = await loaded;
                parent.postMessage(result, "*");
            })();
            </script></body></html>
            """, directory: directory, server: fixture.url("/"))
        try await wait { !probe.values.isEmpty || web.error != nil }
        #expect(web.error == nil)
        let received = try #require(probe.values.first)
        #expect(received["origin"] as? String == "null")
        let result = try #require(received["result"] as? [String: Any])
        #expect(result["scripts"] as? Bool == true)
        #expect(result["parentAccess"] as? Bool == false)
        #expect(result["cookie"] as? String == "")
        #expect(result["api"] as? Bool == false)
        #expect(result["aliasAPI"] as? Bool == false)
        #expect(result["relativeImage"] as? Bool == true)
        #expect(result["base"] as? String == directory.absoluteString)
        #expect(!web.webView.configuration.websiteDataStore.isPersistent)
        let requests = fixture.requests.withLock { $0 }
        #expect(requests.map(\.path) == ["/api/serve/test/documents/pixel.svg"])
        #expect(requests.allSatisfy { !$0.headers.lowercased().contains(fakeCookie.name.lowercased()) })
    }

    @Test func externalLinksOpenTheBrowserInsteadOfReplacingTheEmbeddedDocument() async throws {
        let destination = try #require(URL(string: "https://artifact-viewer-test.invalid/review"))
        var opened: [URL] = []
        let web = ArtifactWebContent(openURL: { opened.append($0); return true })
        defer { web.stop() }
        let server = try #require(URL(string: "http://127.0.0.1:1"))
        await web.load("""
            <a id="external" href="\(destination.absoluteString)">Review</a>
            <script>document.getElementById("external").click();</script>
            """, directory: server.appendingPathComponent("api/serve/test/"), server: server)
        try await wait { !opened.isEmpty || web.error != nil }
        #expect(web.error == nil)
        #expect(opened == [destination])
        #expect(web.webView.url?.scheme == "about")
    }

    @Test func sameDocumentAnchorsScrollInsideTheOpaqueFrameWithoutOpeningTheBrowser() async throws {
        var opened: [URL] = []
        let web = ArtifactWebContent(openURL: { opened.append($0); return true })
        defer { web.stop() }
        web.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let probe = ArtifactWebProbe()
        probe.attach(to: web.webView)
        let server = try #require(URL(string: "http://127.0.0.1:1"))
        await web.load("""
            <a id="jump" href="#target">Jump</a><div style="height:1200px"></div><h2 id="target">Target</h2>
            <script>
            window.addEventListener("scroll",()=>parent.postMessage({jump:scrollY}, "*"));
            document.getElementById("jump").click();
            </script>
            """, directory: server.appendingPathComponent("api/serve/test/"), server: server)
        try await wait { !probe.values.isEmpty || web.error != nil || !opened.isEmpty }
        #expect(web.error == nil)
        #expect(opened.isEmpty)
        let result = try #require(probe.values.first?["result"] as? [String: Any])
        #expect((result["jump"] as? Double ?? 0) > 500)
    }

    @Test func prefixedAndEscapedServerAddressesCompileIntoRealWebKitRules() async throws {
        let server = try #require(URL(string: "http://127.0.0.1:3299/team%20space/"))
        let encoded = try ArtifactWebPolicy.blockingRules(server: server)
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]])
        let allow = try #require(rules.last?["trigger"] as? [String: String])
        #expect(allow["url-filter"]?.contains("team%20space") == true)
        let compiled = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "artifact-viewer-prefix-test", encodedContentRuleList: encoded)
        #expect(compiled != nil)
    }

    @Test func HTMLUsesTheReferenceSandboxPermissionsWithoutSameOrigin() {
        #expect(Set(ArtifactWebPolicy.htmlPermissions) == [
            "allow-downloads", "allow-forms", "allow-modals", "allow-popups",
            "allow-scripts", "allow-top-navigation-by-user-activation",
        ])
    }

    @Test func nativeSVGActuallyRendersAtItsNaturalPointSizeWithoutExecutingScripts() async throws {
        _ = NSApplication.shared
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let artifact = ChannelArtifact(file: .init(kind: "machine", path: "drawing.svg"), title: "Drawing",
                                       url: "/api/serve/test/drawing.svg")
        let loaded = try await ArtifactContent.load(artifact, api: ChannelAPI(baseURL: fixture.url("/")))
        let bitmap = try #require(loaded.bitmap)
        #expect(loaded.imageSize == CGSize(width: 120, height: 80))
        let view = ArtifactImageScrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.stop(); window.contentView = nil; window.close() }
        view.configure(image: NSImage(cgImage: bitmap, size: try #require(loaded.imageSize)),
                       file: loaded.file, isSVG: true)
        view.layoutSubtreeIfNeeded()
        let imageView = view.imageView
        let representation = try #require(imageView.bitmapImageRepForCachingDisplay(in: imageView.bounds))
        imageView.cacheDisplay(in: imageView.bounds, to: representation)
        let scale = CGFloat(representation.pixelsWide) / imageView.bounds.width
        func isRed(_ x: CGFloat, _ y: CGFloat) throws -> Bool {
            let color = try #require(representation.colorAt(x: Int((imageView.bounds.midX + x) * scale),
                                                           y: Int((imageView.bounds.midY + y) * scale))?
                                      .usingColorSpace(.sRGB))
            return color.alphaComponent > 0.9 && color.redComponent > 0.8
                && color.redComponent > color.greenComponent * 3
                && color.redComponent > color.blueComponent * 3
        }
        #expect(try isRed(0, 0))
        #expect(try isRed(59, 0))
        #expect(try !isRed(61, 0))
        #expect(try isRed(0, 39))
        #expect(try !isRed(0, 41))
        #expect(fixture.requests.withLock { $0.map(\.path) } == ["/api/serve/test/drawing.svg"])
    }

    @Test func unvisitedImageThumbnailsLoadAndTheirDownloadedFileIsReused() async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let plan = ChannelArtifact(file: .init(kind: "machine", path: "plan.md"), title: "Plan",
                                   url: "/api/serve/test/plan.md")
        let drawing = ChannelArtifact(file: .init(kind: "machine", path: "drawing.svg"), title: "Drawing",
                                      url: "/api/serve/test/drawing.svg")
        let opener = ArtifactOpener()
        opener.configure(api: try ChannelAPI(baseURL: fixture.url("/")), channelID: "test", artifacts: [plan, drawing],
                         interaction: ChannelInteraction(), imageViewer: ImageViewer())
        defer { opener.close(animated: false) }
        opener.open(plan)
        try await wait { !opener.isLoading && opener.thumbnail(for: drawing) != nil }
        #expect(opener.artifact?.id == plan.id)
        opener.select(drawing.id)
        try await wait { !opener.isLoading }
        #expect(opener.image?.size == CGSize(width: 120, height: 80))
        #expect(fixture.requests.withLock { $0.filter { $0.path.hasSuffix("drawing.svg") }.count } == 1)
    }

    @Test func closingRestoresTheInvokingWindowsResponderWithoutTakingAnotherWindowsFocus() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let control = ArtifactFocusTestView(frame: window.contentView!.bounds)
        window.contentView = control
        #expect(window.makeFirstResponder(control))
        let opener = ArtifactOpener()
        opener.window = window
        opener.open(artifact("plan.md"))
        #expect(window.makeFirstResponder(nil))
        opener.close()
        try await wait { window.firstResponder === control }
        #expect(!window.isKeyWindow)
    }

    @Test func aWebViewOwningFocusKeepsArrowKeysForItsOwnControls() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let web = ArtifactWebContent()
        window.contentView = web.webView
        defer { window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(web.webView))
        let opener = ArtifactOpener()
        opener.window = window
        opener.webView = web.webView
        #expect(!opener.canPageUsingKeys)
    }

    private func artifact(_ path: String, shared: String? = nil) -> ChannelArtifact {
        .init(file: .init(kind: "machine", path: path), title: path, sharedAt: shared)
    }

    @MainActor
    private final class ArtifactFocusTestView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "The artifact did not reach its expected settled state.")
    }
}

@MainActor
private final class ArtifactWebProbe: NSObject, WKScriptMessageHandler {
    var values: [[String: Any]] = []

    func attach(to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.add(self, name: "probe")
        controller.addUserScript(WKUserScript(source: """
            window.addEventListener("message", event => {
                window.webkit.messageHandlers.probe.postMessage({origin:event.origin,result:event.data});
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        #expect(message.frameInfo.isMainFrame)
        if let body = message.body as? [String: Any] { values.append(body) }
        else { Issue.record("The WebKit fixture sent an invalid result.") }
    }
}

private final class ArtifactHTTPFixture: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let headers: String
    }
    let requests = Mutex<[Request]>([])
    let failures = Mutex<Set<String>>([])
    let heldPaths = Mutex<Set<String>>([])
    private let pending = Mutex<[String: NWConnection]>([:])
    private let listener: NWListener
    private let queue = DispatchQueue(label: "artifact-viewer-http-fixture")
    private let starting = Mutex(true)

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: queue)
            receive(connection, accumulated: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if starting.withLock({ value in let first = value; value = false; return first }) {
                        continuation.resume()
                    }
                case .failed(let error):
                    if starting.withLock({ value in let first = value; value = false; return first }) {
                        continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        pending.withLock { connections in
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }
    }

    func release(_ path: String) {
        if let connection = pending.withLock({ $0.removeValue(forKey: path) }) { respond(connection, path: path) }
    }

    func url(_ path: String, host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(listener.port!.rawValue)\(path)")!
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let bytes = accumulated + (data ?? Data())
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || complete { connection.cancel() }
                else { receive(connection, accumulated: bytes) }
                return
            }
            let headers = String(decoding: bytes[..<end.upperBound], as: UTF8.self)
            let path = headers.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            requests.withLock { $0.append(Request(path: path, headers: headers)) }
            if heldPaths.withLock({ $0.contains(path) }) { pending.withLock { $0[path] = connection } }
            else { respond(connection, path: path) }
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        let body = path.hasSuffix(".svg")
            ? #"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect id="marker" width="120" height="80" fill="red"/><script>document.getElementById("marker").setAttribute("fill","green");</script></svg>"#
            : #"{"mustNotBeRead":true}"#
        let type = path.hasSuffix(".svg") ? "image/svg+xml" : "application/json"
        let status = failures.withLock { $0.contains(path) } ? "500 Internal Server Error" : "200 OK"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

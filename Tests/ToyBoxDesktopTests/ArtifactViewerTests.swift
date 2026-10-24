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
        fixture.failures.withLock { $0.insert("/api/serve/test/plan.md") }
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
        fixture.heldPaths.withLock { $0.insert(slowPath) }
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
        let web = ArtifactWebContent(kind: .html, openURL: { _ in
            Issue.record("The fixture must not open a browser.")
            return false
        })
        defer { web.stop() }
        let probe = ArtifactWebProbe()
        let controller = web.webView.configuration.userContentController
        controller.add(probe, name: "probe")
        controller.addUserScript(WKUserScript(source: """
            window.addEventListener("message", event => {
                window.webkit.messageHandlers.probe.postMessage({origin:event.origin,result:event.data});
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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

    @Test func SVGDisablesBothWebPageJavaScriptAndSandboxScriptPermission() throws {
        let web = ArtifactWebContent(kind: .svg)
        #expect(!web.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!web.webView.configuration.websiteDataStore.isPersistent)
        let directory = try #require(URL(string: "http://127.0.0.1:3210/api/serve/test/"))
        let document = ArtifactWebPolicy.document("<svg/>", directory: directory, kind: .svg)
        #expect(document.contains("sandbox=\"\""))
        #expect(!document.contains("allow-same-origin"))
        #expect(!document.contains("allow-scripts"))
        #expect(Set(ArtifactWebPolicy.htmlPermissions) == [
            "allow-downloads", "allow-forms", "allow-modals", "allow-popups",
            "allow-scripts", "allow-top-navigation-by-user-activation",
        ])
    }

    private func artifact(_ path: String, shared: String? = nil) -> ChannelArtifact {
        .init(file: .init(kind: "machine", path: path), title: path, sharedAt: shared)
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
            ? #"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>"#
            : #"{"mustNotBeRead":true}"#
        let type = path.hasSuffix(".svg") ? "image/svg+xml" : "application/json"
        let status = failures.withLock { $0.contains(path) } ? "500 Internal Server Error" : "200 OK"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

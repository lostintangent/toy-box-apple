import AppKit
import ChannelClient
import ChannelKit
import Network
import SwiftUI
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

    @Test(arguments: ["allowed", "blocked", "control"])
    func topLevelSandboxResponseProbe(policy: String) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ArtifactSandboxResponseProbe(), forURLScheme: "toybox-sandbox")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), configuration: configuration)
        let url = try #require(URL(string: "toybox-sandbox://document/\(policy)"))
        web.load(URLRequest(url: url))
        defer { web.stopLoading() }
        try await wait { web.url == url && !web.isLoading }
        #expect(web.title == (policy == "blocked" ? "Initial" : "Scripts ran"))
        if policy != "blocked" {
            let result = try await web.evaluateJavaScript("window.sandboxProbe")
            let probe = try #require(result as? [String: String])
            print("Top-level sandbox \(policy): \(probe)")
            if policy == "allowed" {
                #expect(probe["origin"] == "null")
                #expect(probe["storage"] == "SecurityError")
                #expect(probe["cookieRead"] == "")
            } else {
                #expect(probe["origin"] == "toybox-sandbox://document")
                #expect(probe["storage"] == "allowed")
            }
        }
    }

    @Test(arguments: ["root", "iframe"], [true, false])
    func sandboxViewportInsetsProbe(container: String, beforeLoad: Bool) async throws {
        _ = NSApplication.shared
        let source = """
        <!doctype html><html><head><style>html,body{margin:0;background:orange}</style></head><body>
        <div id="first" style="height:20px;background:red"></div>
        <div style="height:3000px"></div><div id="last" style="height:20px;background:blue"></div>
        <script>
        function report() {
            parent.postMessage({viewport:innerHeight, scroll:scrollY,
                first:document.getElementById("first").getBoundingClientRect().top,
                last:document.getElementById("last").getBoundingClientRect().bottom}, "*");
        }
        addEventListener("load",report);
        addEventListener("resize",report);
        addEventListener("scroll",report);
        addEventListener("message",event=>{if(event.data==="probe-bottom")scrollTo(0,document.scrollingElement.scrollHeight);});
        </script></body></html>
        """
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ArtifactSandboxResponseProbe(document: source), forURLScheme: "toybox-sandbox")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), configuration: configuration)
        let probe = ArtifactWebProbe()
        probe.attach(to: web)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            web.stopLoading()
            web.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
            window.close()
        }
        let insets = NSEdgeInsets(top: 66, left: 0, bottom: 80, right: 0)
        if beforeLoad { web.obscuredContentInsets = insets }
        if container == "root" {
            let url = try #require(URL(string: "toybox-sandbox://document/allowed"))
            web.load(URLRequest(url: url))
        } else {
            let directory = try #require(URL(string: "http://127.0.0.1:1/api/serve/test/"))
            web.loadHTMLString(iframeDocument(source, directory: directory), baseURL: nil)
        }
        try await wait { !web.isLoading && !probe.values.isEmpty }
        if !beforeLoad { web.obscuredContentInsets = insets }
        _ = try await web.takeSnapshot(configuration: nil)
        let target = container == "root" ? "window" : "document.querySelector('iframe').contentWindow"
        _ = try await web.evaluateJavaScript("\(target).postMessage('probe-bottom','*')")
        try await wait {
            probe.values.contains { value in
                guard let result = value["result"] as? [String: Any] else { return false }
                return (result["scroll"] as? Double ?? 0) > 0
            }
        }
        let metrics = try #require(probe.values.last?["result"] as? [String: Any])
        print("Sandbox viewport \(container), beforeLoad=\(beforeLoad), bounds=\(web.bounds), metrics=\(metrics)")
        #expect(metrics["viewport"] as? Double == 254)
        #expect(metrics["last"] as? Double == 254)
        let snapshot = try await web.takeSnapshot(configuration: nil)
        let bitmap = try #require(snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(bitmap.pixelsHigh) / snapshot.size.height
        for y in [5, 70, 200, 250, 320, 350, 390] {
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(CGFloat(y) * scale))?
                .usingColorSpace(.deviceRGB))
            print("Sandbox viewport \(container), beforeLoad=\(beforeLoad), pixel y=\(y): \(color)")
            if y >= 320 {
                if container == "root" {
                    #expect(color.redComponent > 0.7 && color.greenComponent > 0.3 && color.blueComponent < 0.1)
                } else {
                    #expect(color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95)
                }
            }
        }
    }

    @Test(arguments: ["viewport", "content-height", "full-bleed"])
    func iframeSizingKeepsViewportUnitsAndFixedHeadersHonest(route: String) async throws {
        _ = NSApplication.shared
        let scrollPadding = route == "full-bleed" ? "html{scroll-padding:66px 0 80px}" : ""
        let source = """
        <!doctype html><html><head><style>
        html,body{margin:0;background:orange}\(scrollPadding)
        </style></head><body>
        <header id="fixed" style="position:fixed;top:0;height:24px">Fixed header</header>
        <section id="vh" style="height:100vh">Viewport-sized section</section>
        <section id="tail" style="height:600px">Tail</section>
        <script>
        function report() {
            const style=getComputedStyle(document.documentElement);
            parent.postMessage({
                viewport:innerHeight, viewportUnitHeight:document.getElementById("vh").getBoundingClientRect().height,
                documentHeight:document.documentElement.scrollHeight, scroll:scrollY,
                fixedTop:document.getElementById("fixed").getBoundingClientRect().top,
                last:document.getElementById("tail").getBoundingClientRect().bottom,
                paddingTop:parseFloat(style.scrollPaddingTop)||0, paddingBottom:parseFloat(style.scrollPaddingBottom)||0
            }, "*");
        }
        addEventListener("load",report);
        addEventListener("resize",report);
        addEventListener("scroll",report);
        addEventListener("message",event=>{
            if(event.data==="measure")report();
            if(event.data==="bottom"){scrollTo(0,document.documentElement.scrollHeight);report();}
        });
        </script></body></html>
        """
        let directory = try #require(URL(string: "http://127.0.0.1:1/api/serve/test/"))
        var document = iframeDocument(source, directory: directory)
        if route == "full-bleed" {
            document = document.replacingOccurrences(of: "</head>", with: """
                <style>iframe{position:fixed;top:0;left:0;height:400px}html,body{overflow:hidden}</style></head>
                """)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), configuration: configuration)
        let probe = ArtifactWebProbe()
        probe.attach(to: web)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            web.stopLoading()
            web.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
            window.close()
        }
        web.obscuredContentInsets = NSEdgeInsets(top: 66, left: 0, bottom: 80, right: 0)
        web.loadHTMLString(document, baseURL: nil)
        try await wait { !web.isLoading && !probe.values.isEmpty }
        var metrics = try #require(probe.values.last?["result"] as? [String: Any])
        let viewport: Double = route == "full-bleed" ? 400 : 254
        #expect(metrics["viewport"] as? Double == viewport)
        #expect(metrics["viewportUnitHeight"] as? Double == viewport)
        #expect(metrics["documentHeight"] as? Double == viewport + 600)
        #expect(metrics["fixedTop"] as? Double == 0)
        print("Iframe sizing \(route), initial: \(metrics)")
        if route == "content-height" {
            for round in 1...2 {
                let height = try #require(metrics["documentHeight"] as? Double)
                _ = try await web.evaluateJavaScript("document.querySelector('iframe').style.height='\(height)px'")
                try await wait {
                    (probe.values.last?["result"] as? [String: Any])?["viewport"] as? Double == height
                }
                metrics = try #require(probe.values.last?["result"] as? [String: Any])
                #expect(metrics["viewportUnitHeight"] as? Double == height)
                #expect(metrics["documentHeight"] as? Double == height + 600)
                print("Iframe sizing content-height, round \(round): \(metrics)")
            }
            let result = try await web.evaluateJavaScript("""
                window.scrollTo(0,100);
                ({scroll:scrollY,frameTop:document.querySelector("iframe").getBoundingClientRect().top})
                """)
            let parent = try #require(result as? [String: Any])
            #expect(parent["scroll"] as? Double == 100)
            #expect(parent["frameTop"] as? Double == -100)
            #expect(metrics["fixedTop"] as? Double == 0)
            print("Iframe sizing content-height, parent scrolled: \(parent)")
        } else if route == "full-bleed" {
            _ = try await web.evaluateJavaScript("document.querySelector('iframe').contentWindow.postMessage('bottom','*')")
            try await wait {
                (probe.values.last?["result"] as? [String: Any])?["scroll"] as? Double == 600
            }
            metrics = try #require(probe.values.last?["result"] as? [String: Any])
            #expect(metrics["paddingTop"] as? Double == 66)
            #expect(metrics["paddingBottom"] as? Double == 80)
            #expect(metrics["last"] as? Double == 400)
            #expect(metrics["fixedTop"] as? Double == 0)
            print("Iframe sizing full-bleed, scrolled to bottom: \(metrics)")
        }
    }

    @Test func topLevelSandboxRetainsTheFileOnlyNetworkBoundary() async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let directory = fixture.url("/api/serve/test/documents/")
        let api = fixture.url("/api/v1/channels").absoluteString
        let alias = fixture.url("/api/v1/channels", host: "localhost").absoluteString
        let fakeCookie = try #require(HTTPCookie(properties: [
            .name: "toybox-root-sandbox-test-\(UUID().uuidString)", .value: "not-a-credential",
            .domain: "127.0.0.1", .path: "/api/serve/test/",
        ]))
        HTTPCookieStorage.shared.setCookie(fakeCookie)
        defer { HTTPCookieStorage.shared.deleteCookie(fakeCookie) }
        let source = """
        <!doctype html><html><head><base href="\(directory.absoluteString)"></head><body>
        <script>
        (async () => {
            const result = {origin:self.origin, base:document.baseURI, cookie:document.cookie};
            result.api = await fetch("\(api)", {credentials:"include"}).then(() => true, () => false);
            result.aliasAPI = await fetch("\(alias)").then(() => true, () => false);
            const image = new Image();
            const loaded = new Promise(resolve => { image.onload=()=>resolve(true); image.onerror=()=>resolve(false); });
            image.src = "pixel.svg";
            document.body.append(image);
            result.relativeImage = await loaded;
            window.networkProbe = result;
        })();
        </script></body></html>
        """
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ArtifactSandboxResponseProbe(document: source), forURLScheme: "toybox-sandbox")
        let rules = try ArtifactWebPolicy.blockingRules(server: fixture.url("/"))
        let identifier = "artifact-root-sandbox-network-probe"
        let ruleStore = try #require(WKContentRuleListStore.default())
        let compiled = try #require(try await ruleStore.compileContentRuleList(forIdentifier: identifier,
                                                                             encodedContentRuleList: rules))
        configuration.userContentController.add(compiled)
        let web = WKWebView(frame: .zero, configuration: configuration)
        let url = try #require(URL(string: "toybox-sandbox://document/allowed"))
        web.load(URLRequest(url: url))
        defer { web.stopLoading() }
        try await wait { web.url == url && !web.isLoading }
        var result: [String: Any]?
        let deadline = ContinuousClock.now + .seconds(15)
        while result == nil, ContinuousClock.now < deadline {
            result = try await web.evaluateJavaScript("window.networkProbe") as? [String: Any]
            if result == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let probe = try #require(result)
        #expect(probe["origin"] as? String == "null")
        #expect(probe["cookie"] as? String == "")
        #expect(probe["api"] as? Bool == false)
        #expect(probe["aliasAPI"] as? Bool == false)
        #expect(probe["relativeImage"] as? Bool == true)
        #expect(probe["base"] as? String == directory.absoluteString)
        let requests = fixture.requests.withLock { $0 }
        #expect(requests.map(\.path) == ["/api/serve/test/documents/pixel.svg"])
        #expect(requests.allSatisfy { !$0.headers.lowercased().contains(fakeCookie.name.lowercased()) })
        try await ruleStore.removeContentRuleList(forIdentifier: identifier)
    }

    @Test(arguments: ["root", "iframe"])
    func onlyTheFrameSandboxSurvivesDocumentReplacement(container: String) async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let destination = fixture.url("/api/serve/test/next.html")
        fixture.bodies.withLock {
            $0[destination.path] = """
            <!doctype html><html><body><script>
            let storage;
            try { localStorage.setItem("probe","1"); storage="allowed"; }
            catch(error) { storage=error.name; }
            parent.postMessage({origin:self.origin,storage}, "*");
            </script></body></html>
            """
        }
        let source = """
        <!doctype html><html><body><script>location.href="\(destination.absoluteString)";</script></body></html>
        """
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ArtifactSandboxResponseProbe(document: source), forURLScheme: "toybox-sandbox")
        let web = WKWebView(frame: .zero, configuration: configuration)
        let probe = ArtifactWebProbe()
        probe.attach(to: web)
        defer {
            web.stopLoading()
            web.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
        }
        if container == "root" {
            let url = try #require(URL(string: "toybox-sandbox://document/allowed"))
            web.load(URLRequest(url: url))
        } else {
            web.loadHTMLString(iframeDocument(source, directory: fixture.url("/api/serve/test/")), baseURL: nil)
        }
        try await wait { !probe.values.isEmpty }
        let result = try #require(probe.values.last?["result"] as? [String: String])
        print("Sandbox after document replacement \(container): \(result)")
        #expect(result["origin"] == (container == "root" ? String(fixture.url("/").absoluteString.dropLast()) : "null"))
        #expect(result["storage"] == (container == "root" ? "allowed" : "SecurityError"))
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

    @Test func HTMLKeepsAnOpaqueOriginAndCanLoadOnlyTheServersFileResources() async throws {
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
                try { result.parentAccess = parent !== self && !!parent.document; } catch {}
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
        #expect(web.webView.url?.scheme == "toybox-artifact")
    }

    @Test(arguments: ["toc", "resource", "hash"])
    func sameDocumentTOCLinksAndHashChangesStayInsideTheSandbox(method: String) async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        var opened: [URL] = []
        let web = ArtifactWebContent(openURL: { opened.append($0); return true })
        defer { web.stop() }
        web.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        #expect(web.webView.configuration.userContentController.userScripts.isEmpty)
        let probe = ArtifactWebProbe()
        probe.attach(to: web.webView)
        let probeScripts = web.webView.configuration.userContentController.userScripts
        let server = fixture.url("/")
        let resource = server.appendingPathComponent("api/serve/test/toc.html")
        let href = method == "resource" ? resource.absoluteString + "#section" : "#section"
        await web.load("""
            <!doctype html><html><body>
            <table><caption>Contents</caption><tr><td><a id="jump" href="\(href)">Section</a></td></tr></table>
            <div style="height:1200px"></div><h2 id="section">Section</h2><div style="height:1000px"></div>
            <script>
            window.addEventListener("scroll",()=>parent.postMessage({jump:scrollY,origin:self.origin}, "*"));
            </script></body></html>
            """, directory: resource.deletingLastPathComponent(), server: server, resource: resource)
        try await wait { !web.isLoading }
        let original = try #require(web.webView.url)
        _ = try await web.webView.evaluateJavaScript(
            method == "hash" ? "location.hash='section'" : "document.getElementById('jump').click()")
        try await wait { !probe.values.isEmpty || web.error != nil || !opened.isEmpty }
        #expect(web.error == nil)
        #expect(opened.isEmpty)
        let result = try #require(probe.values.last?["result"] as? [String: Any])
        #expect((result["jump"] as? Double ?? 0) > 500)
        #expect(result["origin"] as? String == "null")
        let currentURL = try #require(web.webView.url)
        var current = try #require(URLComponents(url: currentURL, resolvingAgainstBaseURL: false))
        current.fragment = nil
        #expect(current.url == original)
        #expect(fixture.requests.withLock { $0.isEmpty })
        let isolation = try await web.webView.evaluateJavaScript("""
            (() => {
                try { localStorage.setItem("anchor-test","1"); return "allowed"; }
                catch(error) { return error.name; }
            })()
            """)
        #expect(isolation as? String == "SecurityError")
        #expect(web.webView.configuration.userContentController.userScripts == probeScripts)
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

    @Test(arguments: [false, true], [false, true])
    func pagingOwnsFocusAfterOpeningFromTheComposerAndAfterLeavingHTML(
        leavingHTML: Bool, capsLock: Bool
    ) async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let plan = ChannelArtifact(file: .init(kind: "machine", path: "plan.md"), title: "Plan",
                                   sharedAt: "2026-10-24T22:00:00Z", url: "/api/serve/test/plan.md")
        let html = ChannelArtifact(file: .init(kind: "machine", path: "prototype.html"), title: "Prototype",
                                   sharedAt: "2026-10-24T21:00:00Z", url: "/api/serve/test/prototype.html")
        let opener = ArtifactOpener()
        let interaction = ChannelInteraction()
        let images = ImageViewer()
        opener.configure(api: try ChannelAPI(baseURL: fixture.url("/")), channelID: "test",
                         artifacts: [plan, html], interaction: interaction, imageViewer: images)
        let composer = NSTextView()
        composer.string = "Keep this unsent draft."
        let host = ArtifactKeyboardWindow(opener: opener, composer: composer)
        let flags: NSEvent.ModifierFlags = capsLock ? [.numericPad, .function, .capsLock] : [.numericPad, .function]
        defer { opener.close(animated: false); host.window.close() }
        #expect(host.window.makeFirstResponder(composer))
        opener.open(leavingHTML ? html : plan)
        try await wait { !opener.isLoading }
        if leavingHTML {
            try await wait { opener.webView != nil }
            let web = try #require(opener.webView)
            #expect(host.window.makeFirstResponder(web))
            #expect(!opener.canPageUsingKeys)
            try host.press(.rightArrow, modifiers: flags)
            #expect(opener.artifact?.id == html.id)
            // A disappearing native web responder can leave the window itself holding focus.
            #expect(host.window.makeFirstResponder(nil))
            opener.select(plan.id)
        }
        try await wait {
            opener.artifact?.id == plan.id && opener.canPageUsingKeys
                && host.window.firstResponder != nil && host.window.firstResponder !== host.window
        }
        for modifier: NSEvent.ModifierFlags in [.shift, .control, .option, .command] {
            for key: KeyEquivalent in [.leftArrow, .rightArrow] {
                try host.press(key, modifiers: flags.union(modifier))
                #expect(opener.artifact?.id == plan.id)
            }
        }
        try host.press(.rightArrow, modifiers: flags)
        try await wait { opener.artifact?.id == html.id }
        try host.press(.leftArrow, modifiers: flags)
        try await wait { opener.artifact?.id == plan.id }
        #expect(composer.string == "Keep this unsent draft.")
    }

    @Test(arguments: [CGSize(width: 760, height: 560), CGSize(width: 1280, height: 840)])
    func markdownScrollsUnderTheNativeBarsAndRestoresItsReadingPosition(size: CGSize) async throws {
        let fixture = try ArtifactHTTPFixture()
        fixture.bodies.withLock {
            $0["/api/serve/test/long.md"] = (1...120).map { "## Paragraph \($0)\n\nKeep this reading position.\n" }
                .joined(separator: "\n")
        }
        try await fixture.start()
        defer { fixture.stop() }
        let plan = ChannelArtifact(file: .init(kind: "machine", path: "long.md"), title: "Plan",
                                   sharedAt: "2026-10-24T22:00:00Z", url: "/api/serve/test/long.md")
        let other = ChannelArtifact(file: .init(kind: "machine", path: "report.txt"), title: "Report",
                                    sharedAt: "2026-10-24T21:00:00Z", url: "/api/serve/test/report.txt")
        let opener = ArtifactOpener()
        opener.configure(api: try ChannelAPI(baseURL: fixture.url("/")), channelID: "test",
                         artifacts: [plan, other], interaction: ChannelInteraction(), imageViewer: ImageViewer())
        let host = ArtifactKeyboardWindow(opener: opener, composer: NSTextView(), hasToolbar: true, size: size)
        defer { opener.close(animated: false); host.window.close() }
        opener.open(plan)
        try await wait { !opener.isLoading && host.documentScrollView != nil }
        let scroll = try #require(host.documentScrollView)
        let content = try #require(host.window.contentView)
        let canvas = content.convert(content.bounds, to: nil)
        let frame = scroll.convert(scroll.bounds, to: nil)
        #expect(abs(frame.maxY - canvas.maxY) < 1)
        #expect(abs(frame.minY - canvas.minY) < 1)
        #expect(abs(scroll.contentInsets.top - (canvas.maxY - host.window.contentLayoutRect.maxY)) < 1)
        #expect(abs(scroll.contentInsets.bottom - 80) < 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await wait { (opener.scrollOffsets[plan.id] ?? 0) > 500 }
        let offset = try #require(opener.scrollOffsets[plan.id])
        opener.select(other.id)
        try await wait { scroll.window == nil }
        opener.select(plan.id)
        try await wait {
            guard let restored = host.documentScrollView else { return false }
            return abs(restored.contentView.bounds.minY + restored.contentInsets.top - offset) < 1
                && restored.convert(restored.bounds, to: nil) == frame
        }
        let restored = try #require(host.documentScrollView)
        let topInset = restored.contentInsets.top
        opener.actionError = "The document remains visible while this action error is shown."
        try await wait { restored.contentInsets.top > topInset }
        #expect(restored.convert(restored.bounds, to: nil) == frame)
        #expect(restored.contentInsets.bottom == 80)
        opener.actionError = nil
        try await wait { abs(restored.contentInsets.top - topInset) < 1 }
        let document = try #require(restored.documentView)
        let end = document.frame.height - restored.contentView.bounds.height + restored.contentInsets.bottom
        restored.contentView.scroll(to: NSPoint(x: 0, y: end))
        restored.reflectScrolledClipView(restored.contentView)
        try await wait { abs(restored.contentView.bounds.minY - end) < 1 }
        let documentEnd = document.convert(NSPoint(x: document.bounds.midX, y: document.bounds.maxY), to: nil)
        #expect(abs(documentEnd.y - 80) < 1)
    }

    @Test func nativeImageFitAndZoomRemainInsideTheToolbarAndPager() async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let drawing = ChannelArtifact(file: .init(kind: "machine", path: "drawing.svg"), title: "Drawing",
                                      url: "/api/serve/test/drawing.svg")
        let other = artifact("other.md")
        let opener = ArtifactOpener()
        opener.configure(api: try ChannelAPI(baseURL: fixture.url("/")), channelID: "test",
                         artifacts: [drawing, other], interaction: ChannelInteraction(), imageViewer: ImageViewer())
        let host = ArtifactKeyboardWindow(opener: opener, composer: NSTextView(), hasToolbar: true)
        defer { opener.close(animated: false); host.window.close() }
        opener.open(drawing)
        try await wait { !opener.isLoading && opener.nativeImageView?.window != nil }
        let image = try #require(opener.nativeImageView)
        let frame = image.convert(image.bounds, to: nil)
        #expect(abs(frame.maxY - (host.window.contentLayoutRect.maxY - 16)) < 1)
        #expect(abs(frame.minY - 80) < 1)
        #expect(frame.minX == 24)
        #expect(frame.width == 592)
        #expect(image.fitScale == 1)
        #expect(image.magnification == 1)
        let zoom = try #require(opener.zoomActions)
        zoom.zoomIn()
        #expect(image.magnification > 1)
    }

    @Test(arguments: [false, true], [CGSize(width: 760, height: 560), CGSize(width: 1280, height: 840)])
    func HTMLUnderlapsTheBarsAndRestoresItsReadingPosition(tampered: Bool, size: CGSize) async throws {
        let fixture = try ArtifactHTTPFixture()
        fixture.bodies.withLock {
            $0["/api/serve/test/root.html"] = """
            <!doctype html><html><head><style>html,body{margin:0;background:orange}</style></head><body>
            <header id="fixed" style="position:fixed;top:0;height:24px">Fixed header</header>
            <section id="vh" style="height:100vh">Viewport-sized section</section><div style="height:3000px"></div>
            \(tampered ? "<script>Object.defineProperty(window,'scrollY',{get:()=>17});window.scrollTo=()=>{throw new Error('Page override');};</script>" : "")
            </body></html>
            """
        }
        try await fixture.start()
        defer { fixture.stop() }
        let html = ChannelArtifact(file: .init(kind: "machine", path: "root.html"), title: "Root",
                                   url: "/api/serve/test/root.html")
        let other = artifact("other.md")
        let opener = ArtifactOpener()
        opener.configure(api: try ChannelAPI(baseURL: fixture.url("/")), channelID: "test",
                         artifacts: [html, other], interaction: ChannelInteraction(), imageViewer: ImageViewer())
        let host = ArtifactKeyboardWindow(opener: opener, composer: NSTextView(), hasToolbar: true, size: size)
        defer { opener.close(animated: false); host.window.close() }
        opener.open(html)
        try await wait { opener.webView?.url != nil && opener.webRenderer?.isLoading == false }
        let web = try #require(opener.webView)
        let contentView = try #require(host.window.contentView)
        let canvas = contentView.convert(contentView.bounds, to: nil)
        let frame = web.convert(web.bounds, to: nil)
        #expect(canvas.size == size)
        #expect(frame == canvas)
        let top = canvas.maxY - host.window.contentLayoutRect.maxY
        #expect(abs(web.obscuredContentInsets.top - top) < 1)
        #expect(web.obscuredContentInsets.bottom == 80)
        let testWorld = WKContentWorld.world(name: "ArtifactRootGeometryTests")
        let result = try await web.callAsyncJavaScript("""
            window.scrollTo(0,900);
            return {height:innerHeight,vh:document.getElementById("vh").getBoundingClientRect().height,
              fixedTop:document.getElementById("fixed").getBoundingClientRect().top,scroll:scrollY,origin:self.origin}
            """, arguments: [:], in: nil, contentWorld: testWorld)
        let metrics = try #require(result as? [String: Any])
        let viewport = Double(canvas.height - top - 80)
        #expect(metrics["height"] as? Double == viewport)
        #expect(metrics["vh"] as? Double == viewport)
        #expect(metrics["fixedTop"] as? Double == 0)
        #expect(metrics["scroll"] as? Double == 900)
        #expect(metrics["origin"] as? String == "null")
        if tampered { #expect(try await web.evaluateJavaScript("scrollY") as? Double == 17) }
        _ = try await web.takeSnapshot(configuration: nil)
        #expect(web.configuration.userContentController.userScripts.isEmpty)
        opener.select(other.id)
        let savedState = try #require(opener.webReadingStates[html.id])
        #expect(try await savedState.position.value == CGPoint(x: 0, y: 900))
        try await wait { web.window == nil }
        opener.select(html.id)
        try await wait {
            guard let restored = opener.webView else { return false }
            return restored !== web && opener.webRenderer?.isLoading == false
                && restored.convert(restored.bounds, to: nil) == frame
        }
        let restored = try #require(opener.webView)
        #expect(opener.webRenderer?.error == nil)
        let currentState = try #require(opener.webRenderer?.readingState)
        #expect(savedState.document == currentState.document)
        _ = try await restored.takeSnapshot(configuration: nil)
        let restoredResult = try await restored.callAsyncJavaScript("return {scroll:scrollY,origin:self.origin}",
                                                                  arguments: [:], in: nil, contentWorld: testWorld)
        let restoredMetrics = try #require(restoredResult as? [String: Any])
        #expect(restoredMetrics["scroll"] as? Double == 900)
        #expect(restoredMetrics["origin"] as? String == "null")
        opener.close(animated: false)
        #expect(opener.webReadingStates.isEmpty)
    }

    @Test(arguments: ["script", "form", "form-get"])
    func HTMLCannotNavigateOutOfItsCSPDocument(method: String) async throws {
        let fixture = try ArtifactHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let destination = fixture.url("/api/serve/test/next.html")
        let web = ArtifactWebContent(openURL: { _ in
            Issue.record("The fixture must not open a browser.")
            return false
        })
        defer { web.stop() }
        await web.load("""
            <!doctype html><html><body><form id="form" method="\(method == "form-get" ? "get" : "post")" action="\(destination.absoluteString)">
            <input name="probe" value="not-a-credential"></form></body></html>
            """, directory: fixture.url("/api/serve/test/"), server: fixture.url("/"))
        try await wait { !web.isLoading }
        #expect(web.error == nil)
        let url = web.webView.url
        let script = method.hasPrefix("form")
            ? "document.getElementById('form').submit()"
            : "location.href='\(destination.absoluteString)'"
        _ = try await web.webView.evaluateJavaScript(script)
        try await wait { web.error != nil }
        #expect(web.error == ArtifactWebError.rootNavigationUnavailable.localizedDescription)
        #expect(web.webView.url == url)
        let origin = try await web.webView.evaluateJavaScript("self.origin")
        #expect(origin as? String == "null")
        #expect(fixture.requests.withLock { $0.isEmpty })
    }

    @Test(arguments: [false, true])
    func HTMLKeepsItsFinalContentInsideTheUnobscuredViewport(hasPager: Bool) async throws {
        let fixture = try ArtifactHTTPFixture()
        fixture.bodies.withLock {
            $0["/api/serve/test/page.html"] = """
            <!doctype html><html><body style="margin:0;background:orange">
            <div style="height:3000px"></div><p id="last" style="margin:0">Final content</p></body></html>
            """
        }
        try await fixture.start()
        defer { fixture.stop() }
        let html = ChannelArtifact(file: .init(kind: "machine", path: "page.html"), title: "Page",
                                   url: "/api/serve/test/page.html")
        let other = artifact("other.md")
        let opener = ArtifactOpener()
        opener.configure(api: try ChannelAPI(baseURL: fixture.url("/")), channelID: "test",
                         artifacts: hasPager ? [html, other] : [html],
                         interaction: ChannelInteraction(), imageViewer: ImageViewer())
        let host = ArtifactKeyboardWindow(opener: opener, composer: NSTextView(), hasToolbar: true)
        defer { opener.close(animated: false); host.window.close() }
        opener.open(html)
        try await wait { opener.webView?.url != nil && opener.webRenderer?.isLoading == false }
        let web = try #require(opener.webView)
        let contentView = try #require(host.window.contentView)
        let canvas = contentView.convert(contentView.bounds, to: nil)
        let frame = web.convert(web.bounds, to: nil)
        let top = web.obscuredContentInsets.top
        let bottom: CGFloat = hasPager ? 80 : 24
        #expect(frame == canvas)
        for showsError in [false, true, false] {
            opener.actionError = showsError ? "The document remains visible while this action error is shown." : nil
            try await wait {
                showsError ? web.obscuredContentInsets.top > top + 1 : abs(web.obscuredContentInsets.top - top) < 1
            }
            #expect(web.convert(web.bounds, to: nil) == frame)
            #expect(web.obscuredContentInsets.bottom == bottom)
            let result = try await web.evaluateJavaScript("""
                window.scrollTo(0,document.scrollingElement.scrollHeight);
                ({viewport:innerHeight,last:document.getElementById("last").getBoundingClientRect().bottom})
                """)
            let metrics = try #require(result as? [String: Double])
            let viewport = Double(canvas.height - web.obscuredContentInsets.top - bottom)
            let last = try #require(metrics["last"])
            #expect(metrics["viewport"] == viewport.rounded(.down))
            #expect(last <= viewport)
            #expect(viewport - last < 1)
        }
    }

    @MainActor
    private struct ArtifactKeyboardWindow {
        // Match the task-disclosure harness without taking the user's key window.
        private final class KeyWindow: NSWindow {
            override var isKeyWindow: Bool { true }
            override var canBecomeKey: Bool { true }
        }

        let window: NSWindow

        init(opener: ArtifactOpener, composer: NSTextView, hasToolbar: Bool = false,
             size: CGSize = CGSize(width: 640, height: 400)) {
            _ = NSApplication.shared
            let view = NSHostingView(rootView: ArtifactKeyboardHost(opener: opener, composer: composer))
            window = KeyWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                               styleMask: hasToolbar ? [.titled, .fullSizeContentView] : [.borderless],
                               backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            if hasToolbar { window.toolbar = NSToolbar(identifier: "ArtifactScrollTests") }
            window.contentView = view
            opener.window = window
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
        }

        var documentScrollView: NSScrollView? {
            var pending = window.contentView.map { [$0] } ?? []
            while let view = pending.popLast() {
                if let scroll = view as? NSScrollView,
                   let document = scroll.documentView, document.frame.height > scroll.contentSize.height + 1 {
                    return scroll
                }
                pending.append(contentsOf: view.subviews)
            }
            return nil
        }

        func press(_ key: KeyEquivalent, modifiers: NSEvent.ModifierFlags) throws {
            let isRight = key == .rightArrow
            let characters = String(UnicodeScalar(UInt16(isRight ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey))!)
            window.sendEvent(try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: isRight ? 124 : 123)))
        }

    }

    private struct ArtifactKeyboardHost: View {
        let opener: ArtifactOpener
        let composer: NSTextView

        var body: some View {
            ZStack {
                ArtifactComposerControl(view: composer)
                if let artifact = opener.artifact {
                    ArtifactViewerStage(opener: opener, artifact: artifact)
                }
            }
        }
    }

    private struct ArtifactComposerControl: NSViewRepresentable {
        let view: NSTextView
        func makeNSView(context: Context) -> NSTextView { view }
        func updateNSView(_ nsView: NSTextView, context: Context) {}
    }

    private func artifact(_ path: String, shared: String? = nil) -> ChannelArtifact {
        .init(file: .init(kind: "machine", path: path), title: path, sharedAt: shared)
    }

    private func iframeDocument(_ content: String, directory: URL) -> String {
        let document = ArtifactWebPolicy.document(content, directory: directory)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let permissions = ArtifactWebPolicy.htmlPermissions.joined(separator: " ")
        return """
        <!doctype html><html><head><meta name="referrer" content="no-referrer">
        <style>html,body,iframe{width:100%;height:100%;margin:0;border:0}iframe{display:block}</style>
        </head><body><iframe title="Artifact" sandbox="\(permissions)" referrerpolicy="no-referrer" \
        srcdoc="\(document)"></iframe></body></html>
        """
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
private final class ArtifactSandboxResponseProbe: NSObject, WKURLSchemeHandler {
    private let document: String?

    init(document: String? = nil) {
        self.document = document
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var headers = ["Content-Type": "text/html; charset=utf-8", "Referrer-Policy": "no-referrer"]
        if url.path == "/allowed" {
            headers["Content-Security-Policy"] = "sandbox " + ArtifactWebPolicy.htmlPermissions.joined(separator: " ")
        } else if url.path == "/blocked" {
            headers["Content-Security-Policy"] = "sandbox"
        } else if url.path != "/control" {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            urlSchemeTask.didFailWithError(URLError(.badServerResponse))
            return
        }
        let document = document ?? """
        <!doctype html><html><head><title>Initial</title></head><body>
        <p>Opaque top-level sandbox control</p>
        <script>
        function attempt(action) {
            try { action(); return "allowed"; } catch (error) { return error.name; }
        }
        window.sandboxProbe = {
            origin: self.origin,
            storage: attempt(() => localStorage.setItem("probe", "1")),
            cookies: attempt(() => document.cookie = "probe=1"),
            cookieRead: (() => { try { return document.cookie; } catch (error) { return error.name; } })()
        };
        document.title = "Scripts ran";
        </script></body></html>
        """
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data(document.utf8))
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
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
    let bodies = Mutex<[String: String]>([:])
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
        let body = bodies.withLock { $0[path] } ?? (path.hasSuffix(".svg")
            ? #"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect id="marker" width="120" height="80" fill="red"/><script>document.getElementById("marker").setAttribute("fill","green");</script></svg>"#
            : #"{"mustNotBeRead":true}"#)
        let type = path.hasSuffix(".svg") ? "image/svg+xml" : (path.hasSuffix(".html") ? "text/html" : "application/json")
        let status = failures.withLock { $0.contains(path) } ? "500 Internal Server Error" : "200 OK"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

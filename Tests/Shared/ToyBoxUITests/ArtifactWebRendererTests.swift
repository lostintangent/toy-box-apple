import ChannelClient
import Foundation
import Testing
import ToyBoxUI
import WebKit

@Suite("Shared artifact WebKit renderer")
@MainActor
struct ArtifactWebRendererTests {
    @Test func externalLinksOpenTheBrowserInsteadOfReplacingTheEmbeddedDocument() async throws {
        let destination = try #require(URL(string: "https://artifact-viewer-test.invalid/review"))
        let presentation = WebPresentation()
        let web = ArtifactWebRenderer(presentation: presentation)
        defer { web.stop() }
        let server = try #require(URL(string: "http://127.0.0.1:1"))
        await web.load("""
            <a id="external" href="\(destination.absoluteString)">Review</a>
            <script>document.getElementById("external").click();</script>
            """, directory: server.appendingPathComponent("api/serve/test/"), server: server)
        try await wait { !presentation.opened.isEmpty || web.error != nil }
        #expect(web.error == nil)
        #expect(presentation.opened == [destination])
        #expect(web.webView.url?.scheme == "toybox-artifact")
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

    @Test func anObsoleteNativeBrowserCompletionCannotChangeTheClosedRenderer() async throws {
        let presentation = WebPresentation()
        presentation.defersOpening = true
        let web = ArtifactWebRenderer(presentation: presentation)
        defer { web.stop() }
        let server = try #require(URL(string: "http://127.0.0.1:1"))
        await web.load("""
            <a id="external" href="https://artifact-viewer-test.invalid/review">Review</a>
            <script>document.getElementById("external").click();</script>
            """, directory: server.appendingPathComponent("api/serve/test/"), server: server)
        try await wait { presentation.pendingOpen != nil || web.error != nil }
        let completion = try #require(presentation.pendingOpen)
        web.stop()
        completion(false)
        #expect(web.error == nil)
        #expect(!web.isLoading)
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "The artifact did not reach its expected settled state.")
    }
}

@MainActor
private final class WebPresentation: ArtifactWebPresenting {
    var opened: [URL] = []
    var defersOpening = false
    var pendingOpen: (@MainActor @Sendable (Bool) -> Void)?

    func openInBrowser(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        opened.append(url)
        if defersOpening { pendingOpen = completion }
        else { completion(true) }
    }

    func showAlert(_ message: String, for webView: WKWebView,
                   completion: @escaping @MainActor @Sendable () -> Void) -> Bool { false }
    func showConfirmation(_ message: String, for webView: WKWebView,
                          completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool { false }
    func showPrompt(_ prompt: String, defaultText: String?, for webView: WKWebView,
                    completion: @escaping @MainActor @Sendable (String?) -> Void) -> Bool { false }
}

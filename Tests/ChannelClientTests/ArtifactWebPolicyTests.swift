import Foundation
import Testing
@testable import ChannelClient

struct ArtifactWebPolicyTests {
    private let resource = URL(string: "https://example.com/api/serve/test/plan.html")!
    private let directory = URL(string: "https://example.com/api/serve/test/")!

    @Test func rootAddressesAreImmutableAndTheSandboxNeverGrantsSameOrigin() throws {
        let root = try ArtifactWebPolicy.rootDocumentURL("<h1>Plan</h1>", identity: resource)
        #expect(try ArtifactWebPolicy.rootDocumentURL("<h1>Plan</h1>", identity: resource) == root)
        #expect(try ArtifactWebPolicy.rootDocumentURL("<h1>Changed</h1>", identity: resource) != root)
        #expect(ArtifactWebPolicy.contains(URL(string: root.absoluteString + "#section")!, root: root))
        #expect(!ArtifactWebPolicy.contains(resource, root: root))
        let sandbox = try #require(ArtifactWebPolicy.responseHeaders["Content-Security-Policy"])
        #expect(sandbox.hasPrefix("sandbox "))
        #expect(sandbox.contains("allow-scripts"))
        #expect(!sandbox.contains("allow-same-origin"))
        #expect(ArtifactWebPolicy.responseHeaders["Referrer-Policy"] == "no-referrer")
        let html = ArtifactWebPolicy.document("<html><head><title>Plan</title></head></html>", directory: directory)
        #expect(html.contains("<head><base data-toybox-file-base href=\"\(directory)\">"))
    }

    @Test func navigationDistinguishesFragmentsLinksFramesAndReplacementDocuments() throws {
        let root = try ArtifactWebPolicy.rootDocumentURL("Plan", identity: resource)
        func decision(_ url: URL?, _ kind: ArtifactWebPolicy.NavigationKind = .other,
                      main: Bool? = true) -> ArtifactWebPolicy.Decision {
            ArtifactWebPolicy.navigation(url, kind: kind, mainFrame: main, root: root,
                                         directory: directory, resource: resource)
        }
        #expect(decision(root) == .allow)
        #expect(decision(resource, .link) == .external(resource))
        #expect(decision(URL(string: resource.absoluteString + "#summary")!, .link) == .fragment("summary"))
        #expect(decision(resource) == .block(.rootNavigationUnavailable))
        #expect(decision(root, .form) == .block(.rootNavigationUnavailable))
        #expect(decision(URL(string: "file:///etc/passwd")!, .link, main: false) == .block(.blockedNavigation))
        #expect(decision(URL(string: "toybox://channel/test")!, .link, main: nil) == .block(.blockedNavigation))
        #expect(decision(URL(string: "about:blank")!, main: false) == .allow)
        #expect(decision(URL(string: "data:text/html,Hello")!, main: false) == .allow)
        #expect(decision(URL(string: "blob:https://example.com/fixture")!, main: false) == .allow)
        #expect(decision(nil) == .block(.blockedNavigation))
    }

    @Test func webKitBlocksUnsolicitedPopupsAndOnlyPermittedHTTPPopupsOpenExternally() {
        #expect(!ArtifactWebPolicy.allowsUnsolicitedPopups)
        #expect(ArtifactWebPolicy.popup(resource, kind: .other) == .external(resource))
        #expect(ArtifactWebPolicy.popup(resource, kind: .form) == .block(.rootNavigationUnavailable))
        #expect(ArtifactWebPolicy.popup(URL(string: "toybox://channel/test")!, kind: .link) == .block(.blockedNavigation))
        #expect(ArtifactWebPolicy.popup(nil, kind: .other) == .block(.blockedNavigation))
    }
}

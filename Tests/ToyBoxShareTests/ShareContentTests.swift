import AppKit
import Testing
import UniformTypeIdentifiers
@testable import ToyBoxShare

@MainActor
struct ShareContentTests {
    @Test
    func explicitItemsUseAnIsolatedPasteboardAndKeepTheirTypes() throws {
        let pasteboard = NSPasteboard(name: .init("dev.toybox.desktop.share.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/share-example.txt")
        let web = try #require(URL(string: "https://example.com/path?q=1"))
        let image = Data([1, 2, 3])
        let url = try ShareContent.write([.text("Selected words"), .url(web), .file(file),
                                          .image(image, type: UTType.png.identifier)], to: pasteboard)
        #expect(url.scheme == "toybox-desktop")
        #expect(url.host == "quick-send")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            == [.init(name: "pasteboard", value: pasteboard.name.rawValue)])
        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 4)
        #expect(items[0].string(forType: .string) == "Selected words")
        #expect(items[1].string(forType: .URL) == web.absoluteString)
        #expect(items[2].string(forType: .fileURL) == file.absoluteString)
        #expect(items[3].data(forType: .png) == image)
    }

    @Test
    func providersLoadTextURLsAndImagesWithoutReadingTheGeneralClipboard() async throws {
        let text = NSItemProvider(item: "Selected text" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)
        #expect(try await ShareContent.load(text) == .text("Selected text"))
        let url = try #require(URL(string: "https://example.com/shared"))
        let web = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.url.identifier)
        #expect(try await ShareContent.load(web) == .url(url))
        let data = Data([1, 2, 3])
        let image = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        #expect(try await ShareContent.load(image) == .image(data, type: UTType.png.identifier))
        let file = URL(fileURLWithPath: "/Users/example/Documents/readable-document.txt")
        let provider = NSItemProvider(item: file as NSURL, typeIdentifier: UTType.fileURL.identifier)
        #expect(try await ShareContent.load(provider) == .file(file))
    }

    @Test
    func requestTextFallbackAndFailuresAreExplicit() async throws {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "Shared selection")
        #expect(try await ShareContent.load([item]) == [.text("Shared selection")])
        let web = try #require(URL(string: "https://example.com/selected"))
        item.attachments = [NSItemProvider(item: web as NSURL, typeIdentifier: UTType.url.identifier)]
        #expect(try await ShareContent.load([item]) == [.text("Shared selection"), .url(web)])
        item.attachments = [NSItemProvider(item: "Shared selection" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)]
        #expect(try await ShareContent.load([item]) == [.text("Shared selection")])
        await #expect(throws: ShareContent.Failure.self) { try await ShareContent.load([]) }
        await #expect(throws: ShareContent.Failure.self) { try await ShareContent.load(NSItemProvider()) }
    }

    @Test
    func temporaryAndSandboxContainerPathsAreNeverHandedToAgents() async throws {
        for path in ["/tmp/shared.txt", "/private/var/folders/example/shared.txt",
                     "/Users/example/Library/Containers/other.app/Data/shared.txt",
                     "/Users/example/Library/Group Containers/group.example/shared.txt"] {
            #expect(throws: ShareContent.Failure.self) {
                try ShareContent.inPlaceFile(URL(fileURLWithPath: path))
            }
        }
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { _ in
            Issue.record("Unsupported temporary files should not be loaded")
            return nil
        }
        await #expect(throws: ShareContent.Failure.self) { try await ShareContent.load(provider) }
    }
}

import AppKit
import ChannelClient
import ChannelKit
import Network
import Synchronization
import Testing
@testable import ToyBoxDesktop

@Suite("SVG attachments", .serialized)
struct SVGAttachmentTests {
    @Test(arguments: [
        "width=\"320\" height=\"180\"",
        "viewBox=\"0 0 320 180\"",
        "width=\"100%\" height=\"100%\" viewBox=\"0 0 320 180\"",
    ])
    func theNativeVectorRendererPreservesAspectAndTransparency(_ dimensions: String) async throws {
        let file = try svgFile("""
            <svg xmlns="http://www.w3.org/2000/svg" \(dimensions)>
              <defs><linearGradient id="red"><stop stop-color="#ff0000"/><stop offset="1" stop-color="#ff0000"/></linearGradient></defs>
              <rect width="160" height="180" fill="url(#red)"/>
            </svg>
            """)
        defer { try? FileManager.default.removeItem(at: file) }
        let decoded = try await Task.detached {
            try TranscriptSVGImage.decode(file, maximumPixelSize: 640)
        }.value
        #expect(decoded.pixelSize == CGSize(width: 320, height: 180))
        #expect(decoded.image.width == 640 && decoded.image.height == 360)
        let bitmap = NSBitmapImageRep(cgImage: decoded.image)
        let red = try #require(bitmap.colorAt(x: 80, y: 180)?.usingColorSpace(.sRGB))
        #expect(red.redComponent > 0.95)
        #expect(red.redComponent > 2 * red.greenComponent)
        #expect(red.redComponent > 2 * red.blueComponent)
        #expect(red.alphaComponent > 0.95)
        #expect(try #require(bitmap.colorAt(x: 560, y: 180)).alphaComponent == 0)
    }

    @Test func bothAttachmentLoadersRenderSVGWithoutDependingOnTheFilename() async throws {
        let file = try svgFile(Self.picture, suffix: "data")
        defer { try? FileManager.default.removeItem(at: file) }
        let (thumbnail, full) = try await Task.detached {
            (try TranscriptThumbnails.decode(file), try ImageViewer.decode(file, maximumPixelSize: 1280))
        }.value
        #expect(thumbnail.width == 640 && thumbnail.height == 320)
        #expect(full.width == 1280 && full.height == 640)
    }

    @Test func hugeIntrinsicDimensionsAreBoundedBeforeRasterization() async throws {
        let file = try svgFile("""
            <svg xmlns="http://www.w3.org/2000/svg" width="1000000" height="500000">
              <rect width="1000000" height="500000" fill="blue"/>
            </svg>
            """)
        defer { try? FileManager.default.removeItem(at: file) }
        let decoded = try await Task.detached {
            try TranscriptSVGImage.decode(file, maximumPixelSize: 100_000)
        }.value
        #expect(decoded.pixelSize == CGSize(width: 1_000_000, height: 500_000))
        #expect(decoded.image.width == 8192 && decoded.image.height == 4096)
    }

    @MainActor @Test func aDecodedThumbnailRemembersTheVectorsIntrinsicSize() async throws {
        let attachment = ChannelAttachment(name: "cached-vector.svg", mimeType: "image/svg+xml",
                                           base64: Data(Self.picture.utf8).base64EncodedString())
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        let file = try await TranscriptAttachmentCache.shared.file(for: attachment, api: api)
        defer { try? FileManager.default.removeItem(at: file) }
        let thumbnail = try await TranscriptThumbnails.image(at: file, for: attachment, api: api)
        #expect(thumbnail.size == CGSize(width: 640, height: 320))
        #expect(TranscriptThumbnails.pixelSize(for: attachment, api: api) == CGSize(width: 800, height: 400))
        #expect(ImageViewer.knownPixelSize(of: attachment, api: api) == CGSize(width: 800, height: 400))
    }

    @Test(arguments: [
        "",
        "not an image",
        "<svg xmlns=\"http://www.w3.org/2000/svg\"><path",
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"0\" height=\"0\"/>",
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"NaN\" height=\"Infinity\"/>",
        """
        <!DOCTYPE svg [
          <!ENTITY a "1234567890">
          <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
          <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
          <!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">
          <!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;">
          <!ENTITY f "&e;&e;&e;&e;&e;&e;&e;&e;&e;&e;">
          <!ENTITY g "&f;&f;&f;&f;&f;&f;&f;&f;&f;&f;">
          <!ENTITY h "&g;&g;&g;&g;&g;&g;&g;&g;&g;&g;">
          <!ENTITY i "&h;&h;&h;&h;&h;&h;&h;&h;&h;&h;">
        ]>
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><text>&i;</text></svg>
        """,
    ])
    func invalidImagesReachTheExistingErrorPath(_ source: String) async throws {
        let file = try svgFile(source)
        defer { try? FileManager.default.removeItem(at: file) }
        await Task.detached {
            #expect(throws: AttachmentError.invalidImage) { try TranscriptThumbnails.decode(file) }
            #expect(throws: AttachmentError.invalidImage) { try ImageViewer.decode(file, maximumPixelSize: 64) }
        }.value
    }

    @Test func externalResourcesAndScriptsNeverConnectToTheNetwork() async throws {
        let probe = try SVGResourceProbe()
        try await probe.start()
        defer { probe.stop() }
        let endpoint = try #require(probe.listener.port).rawValue
        let origin = "http://127.0.0.1:\(endpoint)"
        _ = try await URLSession.shared.data(from: try #require(URL(string: "\(origin)/positive-control")))
        #expect(probe.connectionCount == 1)
        probe.reset()
        let file = try svgFile("""
            <?xml version="1.0"?>
            <!DOCTYPE svg [<!ENTITY remote SYSTEM "\(origin)/entity">]>
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
                 width="320" height="160" onload="fetch('\(origin)/onload')">
              <style>
                @import url("\(origin)/import.css");
                @font-face {font-family: Remote; src: url("\(origin)/font.woff2")}
                text {font-family: Remote}
              </style>
              <rect width="320" height="160" fill="red"/>
              <rect width="20" height="20" fill="url(\(origin)/paint)" filter="url(\(origin)/filter)"/>
              <image href="\(origin)/href.png" width="20" height="20"/>
              <image xlink:href="\(origin)/xlink.png" width="20" height="20"/>
              <use href="\(origin)/use.svg#shape"/>
              <text x="10" y="50">&remote;</text>
              <script>fetch('\(origin)/script')</script>
            </svg>
            """)
        defer { try? FileManager.default.removeItem(at: file) }
        try await Task.detached {
            _ = try TranscriptThumbnails.decode(file)
            _ = try ImageViewer.decode(file, maximumPixelSize: 640)
        }.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.connectionCount == 0)
    }

    @MainActor @Test func zoomAndDisplayScaleRerasterizeWithoutChangingIntrinsicGeometry() async throws {
        let source = Self.picture.replacingOccurrences(of: "800", with: "12000")
            .replacingOccurrences(of: "400", with: "6000")
        let attachment = ChannelAttachment(name: "vector.svg", mimeType: "image/svg+xml",
                                           base64: Data(source.utf8).base64EncodedString())
        #expect(transcriptAttachmentIsImage(attachment))
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        let viewer = ImageViewer()
        viewer.layout = .init(size: CGSize(width: 1000, height: 800), topInset: 52)
        viewer.open(images: [attachment], at: 0,
                    source: .init(messageID: "svg-test", sender: "Core", timestamp: "2026-10-24T23:00:00Z"),
                    api: api)
        defer {
            viewer.close(animated: false)
            if let cached = TranscriptAttachmentCache.cachedFile(for: attachment, api: api) {
                try? FileManager.default.removeItem(at: cached)
            }
        }
        try await waitFor { viewer.items[0]?.bitmap != nil || viewer.items[0]?.failure != nil }
        #expect(viewer.items[0]?.failure == nil)
        #expect(viewer.items[0]?.isVector == true)
        #expect(viewer.items[0]?.pixelSize == CGSize(width: 12000, height: 6000))
        let fittedFrame = viewer.frame(at: 0, in: try #require(viewer.layout))
        viewer.layout?.displayScale = 3
        try await waitFor { (viewer.items[0]?.bitmap?.width ?? 0) >= 3072 || viewer.items[0]?.failure != nil }
        #expect(viewer.items[0]?.failure == nil)
        #expect(viewer.items[0]?.bitmap?.width == 3072)
        let scaledFrame = viewer.frame(at: 0, in: try #require(viewer.layout))
        #expect(abs(scaledFrame.minX - fittedFrame.minX) < 0.000001)
        #expect(abs(scaledFrame.minY - fittedFrame.minY) < 0.000001)
        #expect(abs(scaledFrame.width - fittedFrame.width) < 0.000001)
        #expect(abs(scaledFrame.height - fittedFrame.height) < 0.000001)
        for _ in 0..<12 { viewer.zoomIn() }
        let frame = viewer.frame(at: 0, in: try #require(viewer.layout))
        try await waitFor { viewer.items[0]?.bitmap?.width == 8192 || viewer.items[0]?.failure != nil }
        #expect(viewer.items[0]?.failure == nil)
        #expect(viewer.items[0]?.bitmap?.width == 8192)
        #expect(viewer.items[0]?.pixelSize == CGSize(width: 12000, height: 6000))
        #expect(viewer.zoom == 8 && frame.size == CGSize(width: 32000, height: 16000))
        #expect(viewer.frame(at: 0, in: try #require(viewer.layout)) == frame)
    }

    @MainActor @Test func aFailedRerasterPreservesTheImageAndARetryRecovers() async throws {
        let source = Self.picture + "\n<!-- reraster recovery -->"
        let attachment = ChannelAttachment(name: "recovery.svg", mimeType: "image/svg+xml",
                                           base64: Data(source.utf8).base64EncodedString())
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        let viewer = ImageViewer()
        viewer.layout = .init(size: CGSize(width: 1000, height: 800), topInset: 52)
        viewer.open(images: [attachment], at: 0,
                    source: .init(messageID: "svg-recovery", sender: "Core", timestamp: "2026-10-24T23:00:00Z"),
                    api: api)
        defer {
            viewer.close(animated: false)
            if let cached = TranscriptAttachmentCache.cachedFile(for: attachment, api: api) {
                try? FileManager.default.removeItem(at: cached)
            }
        }
        try await waitFor { viewer.items[0]?.bitmap != nil || viewer.items[0]?.failure != nil }
        let original = try #require(viewer.items[0]?.bitmap)
        try FileManager.default.removeItem(at: try #require(viewer.items[0]?.file))
        for _ in 0..<12 { viewer.zoomIn() }
        try await waitFor { viewer.items[0]?.failure != nil }
        #expect(viewer.items[0]?.bitmap === original)
        #expect(viewer.items[0]?.pixelSize == CGSize(width: 800, height: 400))
        viewer.retry()
        try await waitFor { (viewer.items[0]?.bitmap?.width ?? 0) >= 6400 || viewer.items[0]?.failure != nil }
        #expect(viewer.items[0]?.failure == nil)
        #expect(viewer.items[0]?.bitmap?.width == 6400)
        #expect(viewer.items[0]?.pixelSize == CGSize(width: 800, height: 400))
    }

    private static let picture = """
        <svg xmlns="http://www.w3.org/2000/svg" width="800" height="400" viewBox="0 0 800 400">
          <rect width="800" height="400" fill="#327785"/>
          <path d="M0 0L800 400M800 0L0 400" stroke="white" stroke-width="1"/>
          <text x="40" y="200" font-size="48" fill="white">Vector attachment</text>
        </svg>
        """

    private func svgFile(_ source: String, suffix: String = "svg") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toybox-svg-\(UUID().uuidString)").appendingPathExtension(suffix)
        try Data(source.utf8).write(to: url)
        return url
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() && .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }
}

private final class SVGResourceProbe: Sendable {
    let listener: NWListener
    private let connections = Mutex(0)

    var connectionCount: Int { connections.withLock { $0 } }
    func reset() { connections.withLock { $0 = 0 } }
    func stop() {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [self] connection in
            connections.withLock { $0 += 1 }
            connection.start(queue: .global())
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<Void, any Error>
                switch state {
                case .ready: result = .success(())
                case .failed(let error): result = .failure(error)
                default: return
                }
                resumed.withLock {
                    guard !$0 else { return }
                    $0 = true
                    continuation.resume(with: result)
                }
            }
            listener.start(queue: .global())
        }
    }
}

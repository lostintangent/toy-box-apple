import ChannelClient
import CoreGraphics
import Foundation
import Testing
@testable import ToyBoxMobile

@Suite("Phone SVG artifacts", .serialized)
struct ArtifactSVGTests {
    private func fixture(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtifactSVG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("drawing.svg")
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let cropped = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                    | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    @Test func aStaticExportRendersColorTransformsTransparencyAndNaturalSize() async throws {
        let file = try fixture("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 20000 10000">
              <defs><linearGradient id="ink"><stop stop-color="#ff0000"/><stop offset="1" stop-color="#ff0000"/></linearGradient></defs>
              <rect width="10000" height="10000" fill="url(#ink)"/>
              <g transform="translate(10000 0)"><path d="M0 0H5000V10000H0Z" fill="#0000ff"/></g>
            </svg>
            """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let decoded = try await ArtifactImageDecoder.decode(file, kind: .svg, maximumPixelSize: 128)
        #expect(decoded.size == CGSize(width: 200, height: 100))
        #expect(decoded.image.width == 128 && decoded.image.height == 64)
        let red = try pixel(decoded.image, x: 20, y: 20)
        let blue = try pixel(decoded.image, x: 80, y: 20)
        #expect(red[0] > 240 && red[1] < 15 && red[2] < 15 && red[3] > 240)
        #expect(blue[0] < 15 && blue[1] < 15 && blue[2] > 240 && blue[3] > 240)
        #expect(try pixel(decoded.image, x: 112, y: 20)[3] == 0)
    }

    @Test func embeddedScriptsAndLoadHandlersCannotChangeTheDrawing() async throws {
        let file = try fixture("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"
                 onload="document.getElementById('ink').setAttribute('fill', '#0000ff')">
              <rect id="ink" width="100" height="100" fill="#ff0000"/>
              <script>document.getElementById('ink').setAttribute('fill', '#00ff00');</script>
            </svg>
            """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let decoded = try await ArtifactImageDecoder.decode(file, kind: .svg, maximumPixelSize: 32)
        let color = try pixel(decoded.image, x: 16, y: 16)
        #expect(color[0] > 240 && color[1] < 15 && color[2] < 15 && color[3] > 240)
    }

    @Test func explicitDimensionsAndViewBoxPreserveNaturalSizeWithoutRendering() throws {
        let square = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"/>
            """.utf8)
        #expect(try SVGDimensions.size(of: square) == CGSize(width: 100, height: 100))
        let viewBox = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20000 10000"/>
            """.utf8)
        let size = try SVGDimensions.size(of: viewBox)
        #expect(size == CGSize(width: 20000, height: 10000))
        #expect(ArtifactImageDecoder.pixelSize(size, maximum: 64) == CGSize(width: 64, height: 32))
    }

    @Test func theRasterBoundNeverExceeds8192AndNeverAllocatesAZeroEdge() {
        #expect(ArtifactImageDecoder.pixelSize(CGSize(width: 20000, height: 10000), maximum: Int.max)
                == CGSize(width: 8192, height: 4096))
        #expect(ArtifactImageDecoder.pixelSize(CGSize(width: 1, height: 10000), maximum: 0)
                == CGSize(width: 1, height: 1))
    }

    @Test func malformedDocumentsAndExternalEntityDeclarationsFailBeforeRendering() async throws {
        for contents in [
            "<html><body>Not SVG</body></html>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><path></svg>",
            """
            <!DOCTYPE svg [<!ENTITY remote SYSTEM "https://example.invalid/private">]>
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><text>&remote;</text></svg>
            """,
            """
            <!DOCTYPE svg [<!ENTITY text "Expanded text">]>
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><text>&text;</text></svg>
            """,
        ] {
            let file = try fixture(contents)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            await #expect(throws: ChannelAttachmentError.invalidImage) {
                _ = try await ArtifactImageDecoder.decode(file, kind: .svg, maximumPixelSize: 32)
            }
        }
    }
}

@MainActor
private final class RenderPage {
    nonisolated let number: Int
    init(number: Int) { self.number = number }
}

@MainActor
private final class RenderLog {
    var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private struct DrawFailure: Error {}

@MainActor
@Suite("Phone SVG page reuse", .timeLimit(.minutes(1)))
struct SVGPageRendererTests {
    private func makeRenderer(deadline: Duration = .seconds(60), idleLifetime: Duration = .seconds(3600),
                              made: RenderLog) -> SVGPageRenderer<RenderPage> {
        SVGPageRenderer(deadline: deadline, idleLifetime: idleLifetime) {
            made.record("page")
            return RenderPage(number: made.events.count)
        }
    }

    private func pageNumber(_ renderer: SVGPageRenderer<RenderPage>) async throws -> Int {
        Int(try await renderer.render { page in Data([UInt8(page.number)]) }[0])
    }

    @Test func rendersShareOnePageUntilADrawFails() async throws {
        let made = RenderLog()
        let renderer = makeRenderer(made: made)
        #expect(try await pageNumber(renderer) == 1)
        #expect(try await pageNumber(renderer) == 1)
        await #expect(throws: DrawFailure.self) { try await renderer.render { _ in throw DrawFailure() } }
        #expect(try await pageNumber(renderer) == 2)
    }

    @Test func aDrawPastTheDeadlineIsCancelledAndItsPageIsReplaced() async throws {
        let made = RenderLog()
        let draws = RenderLog()
        let renderer = makeRenderer(deadline: .milliseconds(10), made: made)
        await #expect(throws: ChannelAPIError.invalidMessage("The SVG preview took too long to render.")) {
            try await renderer.render { _ in
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    await draws.record("cancelled")
                    throw error
                }
                return Data()
            }
        }
        #expect(draws.events == ["cancelled"])
        #expect(try await pageNumber(renderer) == 2)
    }

    @Test func aSecondRenderWaitsForTheFirstToFinish() async throws {
        let renderer = makeRenderer(made: RenderLog())
        let draws = RenderLog()
        let (started, start) = AsyncStream<Void>.makeStream()
        let (opened, open) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await renderer.render { _ in
                await draws.record("first began")
                start.yield()
                for await _ in opened { break }
                await draws.record("first ended")
                return Data()
            }
        }
        for await _ in started { break }
        // Runs synchronously until the render queues behind the first.
        let second = Task.immediate {
            try await renderer.render { _ in
                await draws.record("second began")
                return Data()
            }
        }
        open.yield()
        _ = try await first.value
        _ = try await second.value
        #expect(draws.events == ["first began", "first ended", "second began"])
    }

    @Test func anIdlePageIsReleasedUnlessAnotherRenderArrivesFirst() async throws {
        let made = RenderLog()
        let renderer = makeRenderer(made: made)
        #expect(try await pageNumber(renderer) == 1)
        let cancelled = renderer.idleRelease
        #expect(try await pageNumber(renderer) == 1)
        await cancelled?.value
        #expect(try await pageNumber(renderer) == 1)

        let idle = makeRenderer(idleLifetime: .zero, made: made)
        #expect(try await pageNumber(idle) == 2)
        await idle.idleRelease?.value
        #expect(try await pageNumber(idle) == 3)
    }
}

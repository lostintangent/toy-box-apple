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

    @Test func aStaticFixtureRendersRealColoredPixelsAndPreservesItsNaturalSize() async throws {
        let file = try fixture("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100">
              <defs><linearGradient id="ink"><stop stop-color="#ff0000"/><stop offset="1" stop-color="#ff0000"/></linearGradient></defs>
              <rect width="100" height="100" fill="url(#ink)"/>
              <g transform="translate(100 0)"><path d="M0 0H100V100H0Z" fill="#0000ff"/></g>
            </svg>
            """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let decoded = try await ArtifactImageDecoder.decode(file, kind: .svg, maximumPixelSize: 128)
        #expect(decoded.size == CGSize(width: 200, height: 100))
        #expect(decoded.image.width == 128 && decoded.image.height == 64)
        let red = try pixel(decoded.image, x: 20, y: 20)
        let blue = try pixel(decoded.image, x: 100, y: 20)
        #expect(red[0] > 240 && red[1] < 15 && red[2] < 15 && red[3] > 240)
        #expect(blue[0] < 15 && blue[1] < 15 && blue[2] > 240 && blue[3] > 240)
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

    @Test func transparentPixelsAndViewBoxAspectRatioSurviveRasterization() async throws {
        let file = try fixture("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20000 10000">
              <rect width="10000" height="10000" fill="#00ff00"/>
            </svg>
            """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let decoded = try await ArtifactImageDecoder.decode(file, kind: .svg, maximumPixelSize: 64)
        #expect(decoded.size == CGSize(width: 20000, height: 10000))
        #expect(decoded.image.width == 64 && decoded.image.height == 32)
        #expect(try pixel(decoded.image, x: 50, y: 16)[3] == 0)
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
        ] {
            let file = try fixture(contents)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            await #expect(throws: ChannelAttachmentError.invalidImage) {
                _ = try await ArtifactImageDecoder.decode(file, kind: .svg, maximumPixelSize: 32)
            }
        }
    }
}

import ChannelKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ChannelClient

struct ChannelAttachmentTests {
    @Test func thumbnailsFitTheirBoundsWithoutCroppingOrUpscaling() {
        #expect(transcriptThumbnailSize(CGSize(width: 1200, height: 600)) == CGSize(width: 240, height: 120))
        #expect(transcriptThumbnailSize(CGSize(width: 600, height: 1200)) == CGSize(width: 80, height: 160))
        #expect(transcriptThumbnailSize(CGSize(width: 1, height: 1)) == CGSize(width: 1, height: 1))
        #expect(transcriptThumbnailSize(.zero) == CGSize(width: 44, height: 44))
    }

    @Test func inlineImageSizesComeFromTheHeaderWithoutDecodingThePayload() throws {
        // Noise keeps the PNG large, so the probe has to stop well short of the payload's end.
        let large = try encodedImage(width: 900, height: 600, type: .png)
        #expect(large.count > 500_000)
        #expect(ChannelImageDecoder.headerPixelSize(base64: large) == CGSize(width: 900, height: 600))
        // EXIF orientation 6 is a quarter turn, which the decoded thumbnail applies too.
        let rotated = try encodedImage(width: 400, height: 200, type: .jpeg, orientation: 6)
        #expect(ChannelImageDecoder.headerPixelSize(base64: rotated) == CGSize(width: 200, height: 400))
        #expect(ChannelImageDecoder.headerPixelSize(base64: "bm90IGFuIGltYWdl") == nil)
        #expect(ChannelImageDecoder.headerPixelSize(base64: "%%%") == nil)
    }

    @Test func thumbnailsFromDataAreBoundedAndOriented() throws {
        let rotated = try #require(Data(base64Encoded: try encodedImage(width: 800, height: 400, type: .jpeg, orientation: 6)))
        let thumbnail = try #require(ChannelImageDecoder.thumbnail(data: rotated, maxPixelSize: 224))
        #expect(thumbnail.width == 112)
        #expect(thumbnail.height == 224)
        #expect(ChannelImageDecoder.thumbnail(data: Data("not an image".utf8), maxPixelSize: 224) == nil)
    }

    @Test func thumbnailKeySpacesStaySeparateAndAFailedDecodeIsRemembered() throws {
        let id = UUID()
        let data = try #require(Data(base64Encoded: try encodedImage(width: 40, height: 20, type: .png)))
        let image = try #require(ChannelImageDecoder.thumbnail(data: data, maxPixelSize: 40))
        ChannelThumbnailCache.remember(image, for: .attachment(id.uuidString))
        #expect(ChannelThumbnailCache.image(for: .draftImage(id)) == nil)
        var decodes = 0
        for _ in 0..<2 {
            #expect(ChannelThumbnailCache.image(for: .draftImage(id)) { decodes += 1; return nil } == nil)
        }
        #expect(decodes == 1)
        #expect(ChannelThumbnailCache.image(for: .attachment(id.uuidString)) === image)
    }

    @Test func aSharperScaleDecodesAgainAndTheSharperThumbnailIsKept() async throws {
        let payload = try encodedImage(width: 1000, height: 500, type: .png)
        let attachment = ChannelAttachment(name: "wide.png", mimeType: "image/png", base64: payload)
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        let file = try await ChannelAttachmentCache.shared.file(for: attachment, api: api)

        let standard = try await ChannelThumbnails.image(at: file, for: attachment, api: api, scale: 1)
        #expect(standard.width == 240)
        let retina = try await ChannelThumbnails.image(at: file, for: attachment, api: api, scale: 2)
        #expect(retina.width == 480)
        #expect(try await ChannelThumbnails.image(at: file, for: attachment, api: api, scale: 1) === retina)
        #expect(ChannelThumbnails.remember(standard, for: attachment, api: api) === retina)

        let small = ChannelAttachment(name: "small.png", mimeType: "image/png",
                                      base64: try encodedImage(width: 100, height: 50, type: .png))
        let smallFile = try await ChannelAttachmentCache.shared.file(for: small, api: api)
        let whole = try await ChannelThumbnails.image(at: smallFile, for: small, api: api, scale: 1)
        #expect(try await ChannelThumbnails.image(at: smallFile, for: small, api: api, scale: 2) === whole)
    }

    @Test func aSharpRememberedThumbnailLoadsWithItsFileAndAMissingFileIsFetchedAgain() async throws {
        let attachment = ChannelAttachment(name: "remembered.png", mimeType: "image/png",
                                           base64: try encodedImage(width: 1000, height: 500, type: .png))
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        let first = try await ChannelThumbnails.load(for: attachment, api: api, scale: 2)
        #expect(first.image.width == 480)
        let again = try await ChannelThumbnails.load(for: attachment, api: api, scale: 2)
        #expect(again.image === first.image && again.file == first.file)

        try FileManager.default.removeItem(at: first.file)
        let refetched = try await ChannelThumbnails.load(for: attachment, api: api, scale: 2)
        #expect(refetched.image === first.image)
        #expect(FileManager.default.fileExists(atPath: refetched.file.path))
    }

    @Test func overlappingCommitsKeepTheSharperThumbnail() async throws {
        let payload = try encodedImage(width: 1000, height: 500, type: .png)
        let attachment = ChannelAttachment(name: "overlap.png", mimeType: "image/png", base64: payload)
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        let file = try await ChannelAttachmentCache.shared.file(for: attachment, api: api)
        let standard = try ChannelThumbnails.decode(file, scale: 1).image
        let retina = try ChannelThumbnails.decode(file, scale: 2).image

        for round in 0..<50 {
            let key = ChannelThumbnailCache.Key.draftImage(UUID())
            let images = round.isMultiple(of: 2) ? [retina, standard] : [standard, retina]
            let kept = await withTaskGroup(of: CGImage.self) { group in
                for index in 0..<8 {
                    let image = images[index % 2]
                    group.addTask { ChannelThumbnailCache.rememberSharper(image, for: key) }
                }
                return await group.reduce(into: [CGImage]()) { $0.append($1) }
            }
            #expect(ChannelThumbnailCache.image(for: key) === retina)
            #expect(kept.allSatisfy { $0 === retina || $0 === standard })
        }
    }

    @Test func inlineAttachmentsBecomeLocalQuickLookFiles() async throws {
        let data = Data("Quick Look test \(UUID().uuidString)".utf8)
        let attachment = ChannelAttachment(name: "notes.txt", mimeType: "text/plain", base64: data.base64EncodedString())
        let api = try ChannelAPI(serverURL: "http://localhost:3210/prefix")
        let file = try await ChannelAttachmentCache.shared.file(for: attachment, api: api)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.isFileURL)
        #expect(file.pathExtension == "txt")
        #expect(try Data(contentsOf: file) == data)
        try Data("damaged cache".utf8).write(to: file, options: .atomic)
        let refreshed = try await ChannelAttachmentCache.shared.file(for: attachment, api: api, reload: true)
        #expect(refreshed == file)
        #expect(try Data(contentsOf: refreshed) == data)
    }

    @Test func unsupportedAddressesAndInvalidInlineDataFailExplicitly() async throws {
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        await #expect(throws: ChannelAttachmentError.invalidAddress) {
            try await ChannelAttachmentCache.shared.file(for: .init(url: "file:///not-a-remote-resource"), api: api)
        }
        await #expect(throws: ChannelAttachmentError.invalidData) {
            try await ChannelAttachmentCache.shared.file(for: .init(base64: "not valid base64!"), api: api)
        }
    }

    private func encodedImage(width: Int, height: Int, type: UTType, orientation: Int = 1) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let count = width * height * 4
        let words = (0..<((count + 7) / 8)).map { _ in generator.next() }
        let data = words.withUnsafeBytes { Data($0.prefix(count)) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return (encoded as Data).base64EncodedString()
    }
}

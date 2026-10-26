import AppKit
import ChannelClient

extension ComposerImage {
    var image: NSImage? { NSImage(data: data) }
}

extension ComposerDraft {
    convenience init(fileURL: URL? = nil) {
        self.init(fileURL: fileURL, imageIsReadable: isReadableComposerImage,
                  rasterizeImage: rasterizeComposerImage)
    }

    static func shared(serverURL: URL, channelID: String, scope: Scope = .conversation) -> ComposerDraft {
        shared(serverURL: serverURL, channelID: channelID, scope: scope,
               imageIsReadable: isReadableComposerImage, rasterizeImage: rasterizeComposerImage)
    }
}

private func isReadableComposerImage(_ data: Data) -> Bool { NSImage(data: data) != nil }

private func rasterizeComposerImage(_ data: Data, maxPixelSize: Int) -> CGImage? {
    guard let image = NSImage(data: data), image.size.width.isFinite, image.size.height.isFinite,
          image.size.width > 0, image.size.height > 0 else { return nil }
    let scale = min(1, CGFloat(maxPixelSize) / max(image.size.width, image.size.height))
    let width = max(1, Int(image.size.width * scale))
    let height = max(1, Int(image.size.height * scale))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    guard let representation = image.bestRepresentation(for: bounds, context: graphics, hints: nil) else { return nil }
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.current = previous }
    guard representation.draw(in: bounds) else { return nil }
    return context.makeImage()
}

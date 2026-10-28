import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}
let arguments = CommandLine.arguments
guard arguments.count == 3,
      let image = NSImage(contentsOfFile: arguments[1]),
      let master = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fail("error: Icon Composer did not produce a readable master image.")
}
let iconset = URL(fileURLWithPath: arguments[2])
let renditions: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, pixels) in renditions {
    let scale = CGFloat(pixels) / 1024
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("error: Could not allocate the \(pixels)-pixel icon canvas.")
    }
    context.interpolationQuality = .high
    context.setShadow(
        offset: CGSize(width: 0, height: -10 * scale), blur: 34 * scale,
        color: CGColor(gray: 0, alpha: 0.22))
    context.draw(master, in: CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale))
    guard let rendered = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
        fail("error: Could not encode the \(name) icon rendition.")
    }
    do { try png.write(to: iconset.appendingPathComponent("icon_\(name).png")) }
    catch { fail("error: Writing the \(name) icon rendition failed: \(error.localizedDescription)") }
}

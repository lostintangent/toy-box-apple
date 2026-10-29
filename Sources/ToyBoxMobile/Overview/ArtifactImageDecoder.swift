import ChannelClient
import ChannelKit
import Foundation
import WebKit

enum ArtifactImageDecoder {
    static func decode(_ file: URL, kind: ArtifactContentKind, maximumPixelSize: Int?) async throws -> ArtifactDecodedImage {
        let limit = min(8192, max(1, maximumPixelSize ?? 8192))
        if kind == .svg {
            let source = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: file)
                return (data, try SVGDimensions.size(of: data))
            }.value
            try Task.checkCancellation()
            let pdf = try await SVGImageRenderer.render(source.0, size: source.1)
            let svgLimit = maximumPixelSize.map { min(8192, max(1, $0)) }
                ?? Int(min(8192, max(64, ceil(max(source.1.width, source.1.height) * 2))))
            return try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                guard let provider = CGDataProvider(data: pdf as CFData),
                      let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
                    throw ChannelAttachmentError.invalidImage
                }
                let pixels = pixelSize(source.1, maximum: svgLimit)
                guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw ChannelAttachmentError.invalidImage
                }
                context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: pixels),
                                                             rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(page)
                guard let image = context.makeImage() else { throw ChannelAttachmentError.invalidImage }
                return ArtifactDecodedImage(image: image, size: source.1)
            }.value
        }
        return try await Task.detached(priority: .userInitiated) {
            guard let decoded = ChannelImageDecoder.thumbnail(file: file, maxPixelSize: limit) else {
                throw ChannelAttachmentError.invalidImage
            }
            return ArtifactDecodedImage(image: decoded.image, size: ChannelImageDecoder.pixelSize(file: file))
        }.value
    }

    static func pixelSize(_ size: CGSize, maximum: Int) -> CGSize {
        let edge = CGFloat(min(8192, max(1, maximum)))
        let longest = max(size.width, size.height)
        return CGSize(width: max(1, ceil(size.width / longest * edge)),
                      height: max(1, ceil(size.height / longest * edge)))
    }
}

final class SVGDimensions: NSObject, XMLParserDelegate {
    private var root: [String: String]?
    private var invalid = false

    static func size(of data: Data) throws -> CGSize {
        // XMLParser can accept external entity declarations without invoking its declaration delegate.
        // XML syntax is ASCII; dropping NUL padding also covers UTF-16/32 before the parser validates encoding.
        let syntax = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        var remaining = syntax[...]
        while let declaration = remaining.range(of: "<!DOCTYPE") {
            var quote: Character?
            var end = remaining.endIndex
            for index in remaining[declaration.upperBound...].indices {
                let character = remaining[index]
                if let current = quote {
                    if character == current { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "[" {
                    throw ChannelAttachmentError.invalidImage
                } else if character == ">" {
                    end = remaining.index(after: index)
                    break
                }
            }
            remaining = remaining[end...]
        }
        let delegate = SVGDimensions()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let root = delegate.root else {
            throw ChannelAttachmentError.invalidImage
        }
        let viewBox = root["viewBox"]?.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
        let ratio: Double?
        if let viewBox, viewBox.count == 4, viewBox.allSatisfy(\.isFinite), viewBox[2] > 0, viewBox[3] > 0 {
            ratio = viewBox[2] / viewBox[3]
        } else { ratio = nil }
        let width = length(root["width"])
        let height = length(root["height"])
        let size: CGSize
        switch (width, height, ratio) {
        case (let width?, let height?, _): size = CGSize(width: width, height: height)
        case (let width?, nil, let ratio?): size = CGSize(width: width, height: width / ratio)
        case (nil, let height?, let ratio?): size = CGSize(width: height * ratio, height: height)
        case (nil, nil, _):
            size = viewBox.flatMap { $0.count == 4 ? CGSize(width: $0[2], height: $0[3]) : nil }
                ?? CGSize(width: 300, height: 150)
        case (let width?, nil, nil): size = CGSize(width: width, height: 150)
        case (nil, let height?, nil): size = CGSize(width: 300, height: height)
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ChannelAttachmentError.invalidImage
        }
        return size
    }

    private static func length(_ value: String?) -> Double? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.hasSuffix("%") else { return nil }
        var factor = 1.0
        for (unit, scale) in [("px", 1.0), ("pt", 96.0 / 72), ("pc", 16.0), ("in", 96.0),
                              ("cm", 96.0 / 2.54), ("mm", 96.0 / 25.4), ("q", 96.0 / 101.6)] {
            if value.hasSuffix(unit) { value.removeLast(unit.count); factor = scale; break }
        }
        guard let number = Double(value), number.isFinite, number > 0 else { return nil }
        return number * factor
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard root == nil else { return }
        guard elementName == "svg", namespaceURI == "http://www.w3.org/2000/svg" else {
            invalid = true
            parser.abortParsing()
            return
        }
        root = attributeDict
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        invalid = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?) {
        invalid = true
        parser.abortParsing()
    }
}

@MainActor
private enum SVGImageRenderer {
    private struct AboutBlankOnly: WebPage.NavigationDeciding {
        func decidePolicy(for action: WebPage.NavigationAction,
                          preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
            action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }

    static func render(_ data: Data, size: CGSize) async throws -> Data {
        guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ToyBox-StaticSVG-NoNetwork", encodedContentRuleList: """
            [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
            """) else { throw ChannelAttachmentError.invalidImage }
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        configuration.userContentController.add(rules)
        let page = WebPage(configuration: configuration, navigationDecider: AboutBlankOnly())
        let viewport = ArtifactImageDecoder.pixelSize(size, maximum: 1024)
        let html = """
            <!doctype html><html><head><meta name="viewport" content="width=\(Int(viewport.width)),initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'">
            <style>html,body{margin:0;width:\(Int(viewport.width))px;height:\(Int(viewport.height))px;overflow:hidden;background:transparent}img{display:block;width:100%;height:100%}</style>
            </head><body><img alt="" src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
            """
        return try await withThrowingTaskGroup { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await export(page, html: html, region: CGRect(origin: .zero, size: viewport))
                } onCancel: {
                    Task { @MainActor in page.stopLoading() }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw ChannelAPIError.invalidMessage("The SVG preview took too long to render.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func export(_ page: WebPage, html: String, region: CGRect) async throws -> Data {
        do {
            for try await event in page.load(html: html) where event == .finished {
                try Task.checkCancellation()
                return try await page.exported(as: .pdf(region: .rect(region), allowTransparentBackground: true))
            }
        } catch let error as WebPage.NavigationError {
            switch error {
            case .failedProvisionalNavigation(let underlying): throw underlying
            case .webContentProcessTerminated:
                throw ChannelAPIError.invalidMessage("The SVG renderer stopped unexpectedly.")
            default: throw error
            }
        }
        throw ChannelAttachmentError.invalidImage
    }
}

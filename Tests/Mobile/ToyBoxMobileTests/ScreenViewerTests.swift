import ChannelKit
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import ToyBoxMobile

@MainActor
struct ScreenViewerTests {
    @Test func aSettledPinchHoldsThroughSharperFramesAndAsksForThem() throws {
        let (window, canvas, reports) = try fixture()
        let pixels = canvas.traitCollection.displayScale
        #expect(reports.last == CGSize(width: 400 * pixels, height: 800 * pixels))
        #expect(canvas.pictureView.frame == CGRect(x: 0, y: 0, width: 400, height: 250))
        #expect(canvas.contentInset.top == 275)

        canvas.setZoomScale(4, animated: false)
        canvas.contentOffset = CGPoint(x: 600, y: 100)
        let pinchCount = reports.count
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        #expect(reports.count == pinchCount, "A pinch under way never asks for frames")
        canvas.scrollViewDidEndZooming(canvas, with: canvas.pictureView, atScale: 4)
        #expect(reports.last == CGSize(width: 400 * pixels * 4, height: 800 * pixels * 4))

        let settled = (canvas.zoomScale, canvas.contentOffset)
        // The server rounds a sharper frame's pixels, so its shape can be a step off the last one's.
        canvas.show(try picture(width: 1600, height: 1002, region: #"{"x":600,"y":300,"width":300,"height":150}"#))
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        #expect(canvas.zoomScale == settled.0)
        #expect(canvas.contentOffset == settled.1)
        #expect(canvas.pictureView.frame == CGRect(x: 0, y: 0, width: 1600, height: 1002))
        #expect(canvas.contentSize == CGSize(width: 1600, height: 1002))

        canvas.isActive = false
        #expect(reports.last == .some(nil))
        canvas.isActive = true
        #expect(reports.last == CGSize(width: 400 * pixels * 4, height: 800 * pixels * 4))

        canvas.show(Screen.Picture())
        canvas.layoutIfNeeded()
        #expect(canvas.zoomScale == settled.0, "A reconnect keeps the zoom for the next frame")
        #expect(canvas.contentOffset == settled.1)
        withExtendedLifetime(window) {}
    }

    @Test func aNewViewerSizeKeepsTheZoomAndWhatIsInView() throws {
        let (window, canvas, reports) = try fixture()
        func resize(width: CGFloat, height: CGFloat) {
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            canvas.frame = window.bounds
            canvas.layoutIfNeeded()
        }
        canvas.setZoomScale(4, animated: false)
        canvas.scrollViewDidEndZooming(canvas, with: canvas.pictureView, atScale: 4)
        canvas.contentOffset = CGPoint(x: 200, y: 162.5)
        let kept = CGPoint(x: 0.25, y: 0.5625)
        #expect(distance(of: canvas, from: kept) < 1, "UIKit rounds the offset to the pixel")

        // The keyboard shows.
        resize(width: 400, height: 464)
        let pixels = canvas.traitCollection.displayScale
        #expect(canvas.zoomScale == 4)
        #expect(distance(of: canvas, from: kept) < 1)
        #expect(reports.last == CGSize(width: 400 * pixels * 4, height: 464 * pixels * 4))

        // It rotates, so the picture fits differently at 1×.
        resize(width: 800, height: 400)
        #expect(canvas.zoomScale == 4)
        #expect(canvas.pictureView.bounds.size == CGSize(width: 640, height: 400))
        #expect(distance(of: canvas, from: kept) < 1)

        resize(width: 400, height: 800)
        canvas.contentOffset.y = canvas.contentSize.height - 800
        resize(width: 400, height: 464)
        #expect(canvas.bounds.maxY == canvas.contentSize.height, "The host's bottom stays above the keyboard")
        #expect(canvas.contentOffset.x == 200)

        canvas.setZoomScale(1, animated: false)
        resize(width: 400, height: 800)
        #expect(canvas.pictureView.frame == CGRect(x: 0, y: 0, width: 400, height: 250), "1× simply fits again")
        #expect(canvas.contentOffset == CGPoint(x: 0, y: -275))
    }

    @Test func controlLeavesPanningToTwoFingers() throws {
        let (window, canvas, _) = try fixture()
        #expect(canvas.panGestureRecognizer.minimumNumberOfTouches == 1)

        canvas.hasControl = true
        #expect(canvas.panGestureRecognizer.minimumNumberOfTouches == 2)

        canvas.hasControl = false
        #expect(canvas.panGestureRecognizer.minimumNumberOfTouches == 1)
        withExtendedLifetime(window) {}
    }

    @Test func keyboardTypesOnTheHostAndHidesAgainWithoutLettingGoOfControl() throws {
        let (window, canvas, _) = try fixture()
        window.makeKey()
        var sent: [Screen.Input] = []
        canvas.send = { sent += $0 }
        canvas.hasControl = true
        #expect(canvas.isFirstResponder, "A hardware keyboard's keys reach the host without Keyboard")

        canvas.toggleKeyboard()
        #expect(canvas.typing.isFirstResponder)
        canvas.typing.insertText("hi\n")
        canvas.typing.deleteBackward()
        #expect(sent == [.text("hi"), .key("Enter", down: true), .key("Enter", down: false),
                         .key("Backspace", down: true), .key("Backspace", down: false)])

        canvas.toggleKeyboard()
        #expect(canvas.isFirstResponder)
        canvas.toggleKeyboard()
        canvas.hasControl = false
        #expect(!canvas.typing.isFirstResponder && !canvas.isFirstResponder)
    }

    /// How far the canvas's center is from a point of the picture, given as a fraction of it, in points.
    private func distance(of canvas: ScreenCanvas, from point: CGPoint) -> CGFloat {
        let picture = canvas.pictureView.bounds
        let shown = CGPoint(x: point.x * picture.width, y: point.y * picture.height)
        let center = canvas.pictureView.convert(shown, to: canvas)
        return hypot(center.x - canvas.bounds.midX, center.y - canvas.bounds.midY)
    }

    private func fixture() throws -> (UIWindow, ScreenCanvas, Reports) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.isHidden = false
        let canvas = ScreenCanvas(frame: window.bounds)
        let reports = Reports()
        canvas.report = { reports.sizes.append($0) }
        window.addSubview(canvas)
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        canvas.show(try picture(width: 800, height: 500))
        canvas.layoutIfNeeded()
        return (window, canvas, reports)
    }

    /// A picture of a blank frame, with a changed region over it when given one as JSON.
    private func picture(width: Int, height: Int, region: String? = nil) throws -> Screen.Picture {
        let image = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let frame = { (region: String?) throws -> Screen.Frame in
            let region = region.map { #","region":"# + $0 } ?? ""
            let json = #"{"sequence":1,"width":\#(width),"height":\#(height),"radius":20\#(region)}"#
            return try JSONDecoder().decode(Screen.Frame.self, from: Data(json.utf8))
        }
        var picture = Screen.Picture()
        try picture.apply(frame(nil), image: image)
        if let region { try picture.apply(frame(region), image: image) }
        return picture
    }

    @MainActor private final class Reports {
        var sizes: [CGSize?] = []
        var count: Int { sizes.count }
        var last: CGSize?? { sizes.last }
    }
}

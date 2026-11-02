import Foundation
import SwiftUI
import Testing
@testable import ChannelKit

struct SVGPathTests {
    @Test func allCommandsAndRepeatedCoordinates() throws {
        let path = try SVGPath.parse("M1 2 3 4l2 0H8v2h-1V3C1 2 3 4 5 6s1 2 3 4Q2 3 4 5t2 3a2 3 45 0 1 4 5Z")
        #expect(!path.isEmpty)
        let relative = try SVGPath.parse("m1 2 3 4")
        #expect(relative.currentPoint == CGPoint(x: 4, y: 6))
    }

    @Test func numericSyntax() throws {
        let path = try SVGPath.parse("M.5-.5L1e1 2E+1 3e-1 .2")
        let end = try #require(path.currentPoint)
        #expect(abs(end.x - 0.3) < 0.000001)
        #expect(abs(end.y - 0.2) < 0.000001)
    }

    @Test func arcGeometryAndRadiusCorrection() throws {
        let upper = try SVGPath.parse("M0 10A10 10 0 0 1 20 10")
        #expect(abs(upper.boundingRect.width - 20) < 0.0001)
        #expect(abs(upper.boundingRect.height - 10) < 0.0001)
        #expect(upper.currentPoint == CGPoint(x: 20, y: 10))
        let corrected = try SVGPath.parse("M0 10A1 1 0 0120 10")
        #expect(abs(corrected.boundingRect.height - 10) < 0.0001)
        let degenerate = try SVGPath.parse("M0 0A0 4 0 0 1 10 10")
        #expect(degenerate.currentPoint == CGPoint(x: 10, y: 10))
        let rotated = try SVGPath.parse("M2 3a8 3 45 1 0 12 7")
        #expect(rotated.currentPoint == CGPoint(x: 14, y: 10))
    }

    @Test func smoothControlsReflectOnlyMatchingCurve() throws {
        let path = try SVGPath.parse("M0 0C1 2 3 4 5 6S9 10 11 12L13 14S15 16 17 18Q1 2 3 4T5 6")
        var cubics: [(CGPoint, CGPoint, CGPoint)] = []
        var quadratics: [(CGPoint, CGPoint)] = []
        path.forEach { element in
            switch element {
            case .curve(let end, let first, let second): cubics.append((first, second, end))
            case .quadCurve(let end, let control): quadratics.append((control, end))
            default: break
            }
        }
        #expect(cubics[1].0 == CGPoint(x: 7, y: 8))
        #expect(cubics[2].0 == CGPoint(x: 13, y: 14))
        #expect(quadratics[1].0 == CGPoint(x: 5, y: 6))
    }

    @Test(arguments: ["L1 2", "M0", "M0 0C1 2", "M0 0A2 2 0 2 0 3 4", "M0 0R1 2", "M1e 2", "M1e999 2"])
    func invalidPathsFailExplicitly(_ data: String) {
        #expect(throws: SVGPathError.self) { try SVGPath.parse(data) }
    }
}

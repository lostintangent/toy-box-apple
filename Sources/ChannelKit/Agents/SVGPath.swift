import Foundation
import SwiftUI

public enum SVGPathError: Error, Equatable, LocalizedError {
    case invalidPath(offset: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let offset): "Invalid SVG path at byte \(offset)."
        }
    }
}

public enum SVGPath {
    public static func parse(_ data: String) throws -> Path {
        var parser = Parser(data)
        return try parser.parse()
    }
}

private struct Parser {
    var bytes: [UInt8]
    var index = 0
    var path = Path()
    var current = CGPoint.zero
    var start = CGPoint.zero
    var cubicControl: CGPoint?
    var quadraticControl: CGPoint?
    var previousCommand: UInt8?

    init(_ data: String) { bytes = Array(data.utf8) }

    mutating func parse() throws -> Path {
        var command: UInt8?
        var hasMove = false
        while true {
            skipSeparators()
            guard index < bytes.count else { break }
            if isLetter(bytes[index]) {
                command = bytes[index]
                index += 1
            }
            guard let active = command else { throw invalid() }
            let upper = active >= 97 ? active - 32 : active
            let relative = active >= 97
            guard hasMove || upper == 77 else { throw invalid() }
            if upper == 90 {
                path.closeSubpath()
                current = start
                cubicControl = nil
                quadraticControl = nil
                previousCommand = upper
                command = nil
                continue
            }
            let old = current
            var nextCubic: CGPoint?
            var nextQuadratic: CGPoint?
            switch upper {
            case 77, 76:
                let point = try point(relative: relative)
                if upper == 77 {
                    path.move(to: point)
                    start = point
                    hasMove = true
                    command = relative ? 108 : 76
                } else { path.addLine(to: point) }
                current = point
            case 72:
                let x = try number() + (relative ? current.x : 0)
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: current)
            case 86:
                let y = try number() + (relative ? current.y : 0)
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: current)
            case 67:
                let first = try point(relative: relative)
                let second = try point(relative: relative)
                let end = try point(relative: relative)
                path.addCurve(to: end, control1: first, control2: second)
                current = end
                nextCubic = second
            case 83:
                let first = previousCommand == 67 || previousCommand == 83
                    ? reflect(cubicControl ?? current, about: current) : current
                let second = try point(relative: relative)
                let end = try point(relative: relative)
                path.addCurve(to: end, control1: first, control2: second)
                current = end
                nextCubic = second
            case 81:
                let control = try point(relative: relative)
                let end = try point(relative: relative)
                path.addQuadCurve(to: end, control: control)
                current = end
                nextQuadratic = control
            case 84:
                let control = previousCommand == 81 || previousCommand == 84
                    ? reflect(quadraticControl ?? current, about: current) : current
                let end = try point(relative: relative)
                path.addQuadCurve(to: end, control: control)
                current = end
                nextQuadratic = control
            case 65:
                let rx = try number()
                let ry = try number()
                let rotation = try number()
                let large = try flag()
                let sweep = try flag()
                let end = try point(relative: relative)
                try arc(from: old, to: end, rx: rx, ry: ry, rotation: rotation,
                        large: large, sweep: sweep)
                current = end
            default: throw invalid()
            }
            cubicControl = nextCubic
            quadraticControl = nextQuadratic
            previousCommand = upper
        }
        return path
    }

    mutating func point(relative: Bool) throws -> CGPoint {
        let x = try number()
        let y = try number()
        return CGPoint(x: x + (relative ? current.x : 0), y: y + (relative ? current.y : 0))
    }

    mutating func number() throws -> Double {
        skipSeparators()
        let start = index
        if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
        var digits = 0
        while index < bytes.count && isDigit(bytes[index]) { index += 1; digits += 1 }
        if index < bytes.count && bytes[index] == 46 {
            index += 1
            while index < bytes.count && isDigit(bytes[index]) { index += 1; digits += 1 }
        }
        guard digits > 0 else { throw invalid() }
        if index < bytes.count && (bytes[index] == 101 || bytes[index] == 69) {
            index += 1
            if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
            let exponent = index
            while index < bytes.count && isDigit(bytes[index]) { index += 1 }
            guard index > exponent else { throw invalid() }
        }
        guard let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)),
              number.isFinite else { throw invalid() }
        return number
    }

    mutating func flag() throws -> Bool {
        skipSeparators()
        guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else { throw invalid() }
        defer { index += 1 }
        return bytes[index] == 49
    }

    mutating func arc(from: CGPoint, to: CGPoint, rx originalRX: Double, ry originalRY: Double,
                      rotation: Double, large: Bool, sweep: Bool) throws {
        if from == to { return }
        var rx = abs(originalRX)
        var ry = abs(originalRY)
        guard rx != 0 && ry != 0 else { path.addLine(to: to); return }
        let phi = rotation.truncatingRemainder(dividingBy: 360) * .pi / 180
        let cosine = cos(phi)
        let sine = sin(phi)
        let dx = (from.x - to.x) / 2
        let dy = (from.y - to.y) / 2
        let x = cosine * dx + sine * dy
        let y = -sine * dx + cosine * dy
        let scale = x * x / (rx * rx) + y * y / (ry * ry)
        if scale > 1 { rx *= sqrt(scale); ry *= sqrt(scale) }
        let numerator = rx * rx * ry * ry - rx * rx * y * y - ry * ry * x * x
        let denominator = rx * rx * y * y + ry * ry * x * x
        let factor = (large == sweep ? -1.0 : 1.0) * sqrt(max(0, numerator / denominator))
        let cxPrime = factor * rx * y / ry
        let cyPrime = -factor * ry * x / rx
        let cx = cosine * cxPrime - sine * cyPrime + (from.x + to.x) / 2
        let cy = sine * cxPrime + cosine * cyPrime + (from.y + to.y) / 2
        let ux = (x - cxPrime) / rx
        let uy = (y - cyPrime) / ry
        let vx = (-x - cxPrime) / rx
        let vy = (-y - cyPrime) / ry
        let theta = atan2(uy, ux)
        var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        guard [rx, ry, cx, cy, theta, delta].allSatisfy(\.isFinite) else { throw invalid() }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(segments)
        func transform(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: cx + cosine * rx * x - sine * ry * y,
                    y: cy + sine * rx * x + cosine * ry * y)
        }
        for segment in 0..<segments {
            let a = theta + Double(segment) * step
            let b = a + step
            let alpha = 4 / 3 * tan((b - a) / 4)
            let first = transform(cos(a) - alpha * sin(a), sin(a) + alpha * cos(a))
            let second = transform(cos(b) + alpha * sin(b), sin(b) - alpha * cos(b))
            let end = segment == segments - 1 ? to : transform(cos(b), sin(b))
            path.addCurve(to: end, control1: first, control2: second)
        }
    }

    mutating func skipSeparators() {
        while index < bytes.count && [9, 10, 13, 32, 44].contains(bytes[index]) { index += 1 }
    }

    func invalid() -> SVGPathError { .invalidPath(offset: index) }
    func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
    func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    func reflect(_ point: CGPoint, about center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }
}

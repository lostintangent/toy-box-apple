import CoreGraphics
import Foundation

/// A display or window the Toy Box host can share. A viewer watches one live over the screens socket.
public struct Screen: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// The app that owns a window. Displays have none.
    public var application: String?

    /// Matches title and application as one string, as the web does, so a query can span both.
    public func matches(_ query: String) -> Bool {
        query.isEmpty || [title, application].compactMap(\.self).joined(separator: " ").localizedStandardContains(query)
    }
}

/// Everything the host can share: every display, and its on-screen windows.
public struct ScreenList: Codable, Equatable, Sendable {
    public var displays: [Screen]
    public var windows: [Screen]
}

extension Screen {
    /// Whether a viewed screen is being captured, suspended by the host, or gone for good.
    public enum Status: String, Codable, Sendable { case live, paused, ended }

    /// One image update. A full frame replaces the picture, and a region carries only what changed
    /// since the latest full frame, positioned within it. Width, height and radius are always the full
    /// frame's.
    public struct Frame: Codable, Equatable, Sendable {
        public var sequence: Int
        public var width: Int
        public var height: Int
        /// A window's rounded corners, in pixels. JPEG can't carry their transparency, so viewers clip
        /// to them. Displays have none.
        public var radius: Double?
        public var region: Region?

        public struct Region: Codable, Equatable, Sendable {
            public var x: Int
            public var y: Int
            public var width: Int
            public var height: Int
        }

        /// Reads a packet: two big-endian 32-bit lengths, the frame as JSON, then its JPEG. A region's
        /// empty JPEG restores the full frame.
        public static func unpack(_ packet: Data) throws -> (frame: Frame, jpeg: Data) {
            let header = [UInt8](packet.prefix(8))
            guard header.count == 8 else { throw invalid("Incomplete screen packet header.") }
            let length = { (offset: Int) in header[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
            let (metadata, jpeg) = (length(0), length(4))
            guard packet.count == 8 + metadata + jpeg else {
                throw invalid("Screen packet length does not match its header.")
            }
            let start = packet.startIndex + 8
            let frame = try JSONDecoder().decode(Frame.self, from: packet[start..<start + metadata])
            return (frame, packet[(start + metadata)...])
        }
    }

    /// What the server says as text: the screen's state when a viewer connects and whenever it
    /// changes, or an error for a command it refused. Any other type fails to decode, like any type
    /// from a newer server.
    public enum Message: Decodable, Equatable, Sendable {
        /// The title is known once the screen opens, and the reason says why it's paused or ended.
        /// Control belongs to one viewer across every screen, and a server that predates it never
        /// gives it.
        case state(title: String? = nil, status: Status, reason: String? = nil, hasControl: Bool = false)
        case error(String)

        private enum CodingKeys: String, CodingKey { case type, title, status, reason, hasControl, message }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "state":
                self = try .state(title: container.decodeIfPresent(String.self, forKey: .title),
                                  status: container.decode(Status.self, forKey: .status),
                                  reason: container.decodeIfPresent(String.self, forKey: .reason),
                                  hasControl: container.decodeIfPresent(Bool.self, forKey: .hasControl) ?? false)
            case "error":
                self = try .error(container.decode(String.self, forKey: .message))
            case let type:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                       debugDescription: "Unknown screen message type \(type).")
            }
        }
    }

    /// What a viewer shows: the latest full frame, and at most one region drawn over it. A region
    /// never applies to another region, so one a slow viewer skipped leaves no stale pixels behind.
    public struct Picture: Sendable {
        public private(set) var image: CGImage?
        public private(set) var region: (image: CGImage, bounds: Frame.Region)?
        /// The full frame's size and rounded corners, in pixels.
        public private(set) var size = CGSize.zero
        public private(set) var radius = 0.0

        public init() {}

        /// Applies a frame and its decoded JPEG, which a region that restores the full frame lacks.
        public mutating func apply(_ frame: Frame, image: CGImage?) throws {
            if let bounds = frame.region {
                guard self.image != nil else { throw invalid("A screen region arrived before its full frame.") }
                region = image.map { ($0, bounds) }
            } else {
                guard let image else { throw invalid("A full screen frame arrived without its image.") }
                self.image = image
                region = nil
            }
            size = CGSize(width: frame.width, height: frame.height)
            radius = frame.radius ?? 0
        }

        /// Where a point lands on the frame, fitted and centered in `bounds`, as fractions of it from
        /// its top left. A point off the frame, including its far edges, which the host can't press,
        /// lands nowhere.
        public func position(of point: CGPoint, fittedIn bounds: CGRect) -> CGPoint? {
            guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let (width, height) = (size.width * scale, size.height * scale)
            let x = (point.x - bounds.minX - (bounds.width - width) / 2) / width
            let y = (point.y - bounds.minY - (bounds.height - height) / 2) / height
            return (0..<1).contains(x) && (0..<1).contains(y) ? CGPoint(x: x, y: y) : nil
        }
    }
}

private func invalid(_ description: String) -> DecodingError {
    DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
}

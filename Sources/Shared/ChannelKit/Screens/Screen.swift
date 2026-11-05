import CoreGraphics
import Foundation

/// A display or window the Toy Box host can share. A viewer watches one live over the screens socket.
public struct Screen: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// The app that owns a window. Displays have none.
    public var application: String?

    public func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedStandardContains(query)
            || application?.localizedStandardContains(query) == true
    }
}

/// Everything the host can share: every display, and its on-screen windows.
public struct ScreenList: Codable, Equatable, Sendable {
    public var version: Int
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

    /// What the server says as text when a viewer connects and whenever the screen changes. Its only
    /// other text, an error, has no status, so it fails to decode like any type from a newer server.
    public struct Message: Decodable, Equatable, Sendable {
        /// Known once the screen opens.
        public var title: String?
        public var status: Status
        /// Why the screen is paused or ended.
        public var reason: String?
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
    }
}

private func invalid(_ description: String) -> DecodingError {
    DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
}

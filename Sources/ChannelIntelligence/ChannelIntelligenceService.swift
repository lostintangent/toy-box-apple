import Foundation
import SwiftUI

/// On-device catch-up summaries and image alt text. Every result is optional: when the model is
/// unavailable, unsure or refuses, callers render nothing.
public protocol ChannelIntelligenceService: Sendable {
    /// Cheap and synchronous, so a surface can skip its loading state on Macs that can't run the model.
    var availability: IntelligenceAvailability { get }
    func catchUp(_ request: CatchUpRequest) async -> CatchUpResult
    func altText(_ request: AltTextRequest) async -> AltText?
}

public enum IntelligenceUnavailableReason: Sendable, Hashable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLanguage
}

public enum IntelligenceAvailability: Sendable, Hashable {
    case available
    case unavailable(IntelligenceUnavailableReason)

    public var isAvailable: Bool { self == .available }
}

public struct CatchUp: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public let text: String
        /// Message sequences the line is grounded in, without repeats. The first is the message the
        /// line is most about, so it supplies the avatar and is what Reveal shows.
        public let sources: [Int]

        public init(text: String, sources: [Int]) {
            var seen = Set<Int>()
            self.text = text
            self.sources = sources.filter { seen.insert($0).inserted }
        }
    }

    /// Present only while a request is pending. Its sources are the request's sequence.
    public let needsYou: Line?
    /// Up to three changes, most important first.
    public let changes: [Line]
    /// The last sequence the summary considered.
    public let through: Int

    public init(needsYou: Line?, changes: [Line], through: Int) {
        self.needsYou = needsYou
        self.changes = changes
        self.through = through
    }
}

public enum CatchUpResult: Sendable, Hashable {
    case ready(CatchUp)
    /// The model ran and nothing meaningful and grounded survived.
    case nothingNew
    case unavailable(IntelligenceUnavailableReason)
    /// Guardrail refusals, context overflow, timeouts and other generation failures.
    case declined

    public var catchUp: CatchUp? {
        if case .ready(let catchUp) = self { return catchUp }
        return nil
    }
}

public struct AltText: Sendable, Hashable, Codable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct AltTextRequest: Sendable, Hashable {
    public enum Priority: Int, Sendable, Comparable {
        /// A tile on screen.
        case visible
        /// An image the reader opened or focused with VoiceOver. Runs before visible tiles.
        case focused

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let server: String
    /// The attachment cache's SHA-256 identity digest.
    public let digest: String
    public let fileURL: URL
    public let priority: Priority

    public init(server: URL, digest: String, fileURL: URL, priority: Priority = .visible) {
        self.server = intelligenceServerKey(server)
        self.digest = digest
        self.fileURL = fileURL
        self.priority = priority
    }

    var key: String { server + "\n" + digest }
}

func intelligenceServerKey(_ server: URL) -> String {
    var value = server.absoluteString.lowercased()
    while value.hasSuffix("/") { value.removeLast() }
    return value
}

private struct ChannelIntelligenceEnvironmentKey: EnvironmentKey {
    static let defaultValue: any ChannelIntelligenceService = LiveChannelIntelligence.shared
}

extension EnvironmentValues {
    public var channelIntelligence: any ChannelIntelligenceService {
        get { self[ChannelIntelligenceEnvironmentKey.self] }
        set { self[ChannelIntelligenceEnvironmentKey.self] = newValue }
    }
}

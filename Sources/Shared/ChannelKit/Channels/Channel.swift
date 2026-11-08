import Foundation

public struct Channel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var purpose: String?
    public var directory: String?
    public var model: ModelConfiguration
    public var tasks: [ChannelTask]
    public var preview: ChannelPreview?
    public var previewUrl: String?
    public var latestSequence: Int
    public var seenThrough: Int
    public var completedSequence: Int?
    public var requestSequence: Int?
    public var updatedAt: String

    public init(id: String, name: String, purpose: String? = nil, directory: String? = nil,
                model: ModelConfiguration, tasks: [ChannelTask] = [], preview: ChannelPreview? = nil,
                latestSequence: Int = 0, seenThrough: Int = 0, completedSequence: Int? = nil,
                requestSequence: Int? = nil, updatedAt: String) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.directory = directory
        self.model = model
        self.tasks = tasks
        self.preview = preview
        self.latestSequence = latestSequence
        self.seenThrough = seenThrough
        self.completedSequence = completedSequence
        self.requestSequence = requestSequence
        self.updatedAt = updatedAt
    }

    public var resolvedPreview: ChannelPreview? {
        preview ?? previewUrl.map { ChannelPreview(kind: "url", url: $0) }
    }

    public static func nameError(_ name: String) -> String? {
        name.utf16.count > 100 ? "Channel names are limited to 100 characters." : nil
    }

    public static func purposeError(_ purpose: String) -> String? {
        purpose.utf16.count > 12_000 ? "Purpose is limited to 12,000 characters." : nil
    }

    public static func directoryError(_ directory: String) -> String? {
        directory.utf16.count > 4_096 ? "Working directory paths are limited to 4,096 characters." : nil
    }
}

extension Channel {
    public enum Attention: String, Sendable {
        case waiting, finished, unread
    }

    public var attention: Attention? {
        if requestSequence != nil { return .waiting }
        if (completedSequence ?? 0) > seenThrough { return .finished }
        return latestSequence > seenThrough ? .unread : nil
    }

    public func sidebarAttention(isOpen: Bool) -> Attention? {
        let attention = attention
        return attention == .waiting || !isOpen ? attention : nil
    }

    /// Reads the channel through `sequence`. A read only ever moves forward.
    public mutating func read(through sequence: Int) {
        seenThrough = max(seenThrough, sequence)
    }

    public var unreadAfter: Int? {
        latestSequence > seenThrough ? seenThrough : nil
    }

    public var purposePreview: String? {
        let line = purpose?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

    public func matches(_ query: String) -> Bool {
        query.isEmpty || name.localizedStandardContains(query)
            || purpose?.localizedStandardContains(query) == true
            || directory?.localizedStandardContains(query) == true
    }
}

extension Array where Element == Channel {
    /// The matching channels among the three most recent, in that order, then every other match A to Z.
    public func choices(matching query: String, recentIDs: [String]) -> (recent: [Channel], others: [Channel]) {
        let matching = filter { $0.matches(query) }
        let recent = recentIDs.prefix(3).compactMap { id in matching.first { $0.id == id } }
        let recentIDs = Set(recent.map(\.id))
        return (recent, matching.filter { !recentIDs.contains($0.id) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        })
    }
}

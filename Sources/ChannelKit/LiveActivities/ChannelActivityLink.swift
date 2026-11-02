import Foundation

public struct ChannelActivityLink: Equatable, Sendable {
    public var channelID: String
    public var registrationID: String
    public var sequence: Int?

    public init(channelID: String, registrationID: String, sequence: Int? = nil) {
        self.channelID = channelID
        self.registrationID = registrationID
        self.sequence = sequence
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "toybox-desktop", parts.host == "activity", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, (2...3).contains(items.count),
              Set(items.map(\.name)) == (items.count == 2 ? ["channel", "registration"]
                  : ["channel", "registration", "sequence"]),
              let channel = items.first(where: { $0.name == "channel" })?.value, !channel.isEmpty,
              let registration = items.first(where: { $0.name == "registration" })?.value, !registration.isEmpty
        else { return nil }
        let sequence: Int?
        if let item = items.first(where: { $0.name == "sequence" }) {
            guard let value = item.value, let parsed = Int(value), parsed > 0 else { return nil }
            sequence = parsed
        } else { sequence = nil }
        self.init(channelID: channel, registrationID: registration, sequence: sequence)
    }

    public var url: URL? {
        guard !channelID.isEmpty, !registrationID.isEmpty else { return nil }
        if let sequence, sequence <= 0 { return nil }
        var parts = URLComponents()
        parts.scheme = "toybox-desktop"
        parts.host = "activity"
        parts.queryItems = [.init(name: "channel", value: channelID),
                            .init(name: "registration", value: registrationID)]
        if let sequence { parts.queryItems?.append(.init(name: "sequence", value: String(sequence))) }
        return parts.url
    }
}

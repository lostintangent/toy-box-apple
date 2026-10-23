import ChannelKit

extension ChannelAgent {
    static func lead(id: String) -> ChannelAgent {
        .lead(id: id, profile: .init(name: "Lead", role: "Test channel coordinator.",
                                     avatar: .init(mark: "M4 12H20", color: "#123456")))
    }
}

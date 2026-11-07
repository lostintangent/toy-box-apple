import Foundation

extension ChannelNotification {
    /// A reply typed into a notification, addressed the way the in-app Reply addresses it.
    public struct Reply: Equatable, Sendable {
        public let content: String

        /// Nil when there's nothing to send. The text leads with `@handle` unless it already starts with a mention.
        public init?(_ text: String, to handle: String?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let handle, trimmed.firstMatch(of: /^@[a-zA-Z0-9]/) == nil else {
                content = trimmed
                return
            }
            content = "@\(handle) \(trimmed)"
        }
    }
}

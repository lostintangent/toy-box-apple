import Foundation

extension ChannelNotification {
    /// The words one notification shows. Each app adds its own title and renders this body.
    public struct Content: Equatable, Sendable {
        public static let bodyLimit = 400
        public static let waitingBody = "Your team is waiting for your reply."
        public static let requestPlaceholder = "Waiting for your reply"
        public static let completionPlaceholder = "Tasks completed"
        /// A waiting request whose requester or words aren't known yet.
        public static let needsReply = "Needs your reply"

        public let body: String

        private init(body: String) {
            self.body = body
        }

        /// The request as a reader sees it in the transcript, or the waiting copy when it has no words or attachments.
        public init(request: ChannelRequestMessage) {
            self.init(body: Self.requestText(request))
        }

        public init(completion tasks: [ChannelTask]) {
            let text: String
            switch tasks.count {
            case 0: text = "All tasks completed"
            case 1: text = "Completed \u{201C}\(tasks[0].title)\u{201D}"
            case let count: text = "All \(count) tasks completed"
            }
            self.init(body: text)
        }

        public static func subtitle(requester: String) -> String {
            "\(requester) needs your reply"
        }

        public static func truncated(_ text: String, limit: Int = Content.bodyLimit) -> String {
            guard text.count > limit else { return text }
            let prefix = text.prefix(limit - 1)
            let cut = prefix.lastIndex(where: \.isWhitespace).map { prefix[..<$0] } ?? prefix
            return cut.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.-"))) + "\u{2026}"
        }

        private static func requestText(_ request: ChannelRequestMessage) -> String {
            let message = request.message
            let stripped = AgentMentions.removingLeadingMentions(from: message.text, agents: request.agents)
            let onlyMentions = stripped.wholeMatch(of: /(\s*@[a-zA-Z0-9][a-zA-Z0-9-]*[\s,:]*)+/) != nil
            let text = onlyMentions ? "" : MarkdownBlock.plainText(stripped)
            if !text.isEmpty { return truncated(text) }
            let attachments = message.attachments ?? []
            guard !attachments.isEmpty else { return waitingBody }
            let images = attachments.allSatisfy(\.isImage)
            switch (images, attachments.count) {
            case (true, 1): return "Sent an image"
            case (true, let count): return "Sent \(count) images"
            case (false, 1): return "Sent a file"
            case (false, let count): return "Sent \(count) files"
            }
        }
    }
}

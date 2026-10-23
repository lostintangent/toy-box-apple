import AppIntents

/// The Catch Me Up card's Reply. It asks what to say, confirms, then sends once through the same
/// outbox as the composer, mentioning whoever asked the way the transcript's Reply does.
struct ReplyIntent: AppIntent {
    static let title: LocalizedStringResource = "Reply"
    static let description = IntentDescription("Replies in a channel after you confirm it.")
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Channel")
    var channel: ChannelEntity

    /// The agent the reply mentions, by name.
    @Parameter(title: "Recipient")
    var recipient: String?

    /// The request's sequence, which the card shows as Replied once this sends.
    @Parameter(title: "Request")
    var request: Int?

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String?

    @AppDependency var context: ChannelIntentsContext

    init() {}

    init(channel: ChannelEntity, recipient: String?, request: Int?, message: String? = nil) {
        self.channel = channel
        self.recipient = recipient
        self.request = request
        self.message = message
    }

    func perform() async throws -> some IntentResult {
        var text = message ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let question: IntentDialog = if let recipient { "What do you want to say to \(recipient)?" }
                else { "What do you want to say?" }
            text = try await $message.requestValue(question)
        }
        try await context.reply(text, to: channel.id, recipient: recipient, request: request) { prompt in
            try await requestConfirmation(actionName: .send, dialog: "\(prompt.question)")
        }
        return .result()
    }
}

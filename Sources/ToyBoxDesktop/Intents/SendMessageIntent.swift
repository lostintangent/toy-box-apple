import AppIntents

/// Sends once, after you confirm the channel and the words, through the same outbox as the
/// composer.
struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription(
        "Sends a message to a channel after you confirm it. If it can't be sent, it waits in the channel so you can send it again."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Channel", requestValueDialog: "Which channel?")
    var channel: ChannelEntity

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What do you want to say?")
    var message: String

    @AppDependency var context: ChannelIntentsContext

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$channel)")
    }

    init() {}

    init(channel: ChannelEntity, message: String) {
        self.channel = channel
        self.message = message
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await context.send(message, to: channel.id) { prompt in
            try await requestConfirmation(
                actionName: .send,
                dialog: "Send \u{201C}\(prompt.message)\u{201D} to \(prompt.channel)?"
            )
        }
        return .result(dialog: "Sent to \(name).")
    }
}

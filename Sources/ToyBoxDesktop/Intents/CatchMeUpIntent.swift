import AppIntents

/// What's new, said aloud, without opening a window or marking anything as read.
struct CatchMeUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Catch Me Up"
    static let description = IntentDescription(
        "Tells you what needs your attention in your channels, or what's new in one channel. Nothing is marked as read.",
        resultValueName: "Catch-Up"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Channel", description: "Leave empty to hear about every channel that needs you.")
    var channel: ChannelEntity?

    @AppDependency var context: ChannelIntentsContext

    static var parameterSummary: some ParameterSummary {
        Summary("Catch me up on \(\.$channel)")
    }

    init() {}

    init(channel: ChannelEntity?) {
        self.channel = channel
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await context.catchUp(channelID: channel?.id)
        return .result(value: answer, dialog: "\(answer)")
    }
}

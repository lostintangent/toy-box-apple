import AppIntents

struct OpenChannelIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Channel"
    static let description = IntentDescription("Opens a channel in Toy Box.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Channel", requestValueDialog: "Which channel?")
    var target: ChannelEntity

    @AppDependency var context: ChannelIntentsContext

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    init() {}

    init(target: ChannelEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        context.open(target.id)
        return .result()
    }
}

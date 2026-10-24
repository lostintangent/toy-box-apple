import AppIntents

struct OpenRequestIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Request"
    static let description = IntentDescription("Reveals a waiting request in its channel.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Request")
    var target: WaitingRequestEntity

    @AppDependency var context: ChannelIntentsContext

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }

    init() {}
    init(target: WaitingRequestEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await context.openRequest(target.entry)
        return .result()
    }
}

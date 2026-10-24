import AppIntents
import Foundation

/// A discoverable entity action, unlike the Catch Me Up card's private Reply intent.
struct ReplyToRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Reply to Request"
    static let description = IntentDescription("Replies to a waiting request after you confirm the message.",
                                               categoryName: "Messages", searchKeywords: ["Reply", "Answer"])
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Request")
    var request: WaitingRequestEntity

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    @AppDependency var context: ChannelIntentsContext
    /// Retained by this invocation, including a repeated perform after an uncertain delivery.
    let sendID = UUID().uuidString

    static var parameterSummary: some ParameterSummary {
        Summary("Reply to \(\.$request) with \(\.$message)")
    }

    init() {}
    init(request: WaitingRequestEntity, message: String) {
        self.request = request
        self.message = message
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await context.replyToRequest(request.entry, message: message, id: sendID) { prompt in
            try await requestConfirmation(actionName: .send, dialog: "\(prompt.question)")
        }
        return .result(dialog: "Sent to \(request.channelName).")
    }
}

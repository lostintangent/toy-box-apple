import AppIntents
import SwiftUI

/// Draws Catch Me Up's card. The system runs it again after each of the card's buttons, so it only
/// reads: the card it carries, and whether you've replied since.
struct CatchUpSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Catch-Up Card"
    static let isDiscoverable = false

    @Parameter(title: "Card")
    var card: String

    @AppDependency var context: ChannelIntentsContext

    init() {}

    init(card: CatchUpCard) {
        self.card = card.encoded
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: CatchUpSnippet(card: CatchUpCard(encoded: card).map(context.withReplies)))
    }
}

private struct CatchUpSnippet: View {
    let card: CatchUpCard?

    var body: some View {
        if let card { CatchUpCardView(card: card) }
    }
}

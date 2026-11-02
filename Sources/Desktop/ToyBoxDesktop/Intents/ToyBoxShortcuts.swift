import AppIntents

/// The phrases Siri and Spotlight offer without any setup.
struct ToyBoxShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .navy

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CatchMeUpIntent(),
            phrases: [
                "Catch me up in \(.applicationName)",
                "What's new in \(.applicationName)",
                "Catch me up on \(\.$channel) in \(.applicationName)",
                "What's new in \(\.$channel) in \(.applicationName)",
                "Summarize \(\.$channel) in \(.applicationName)",
            ],
            shortTitle: "Catch Me Up",
            systemImageName: "text.line.3.summary"
        )
        AppShortcut(
            intent: OpenChannelIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Show \(\.$target) in \(.applicationName)",
                "Open a channel in \(.applicationName)",
            ],
            shortTitle: "Open Channel",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: [
                "Send a message in \(.applicationName)",
                "Send a message to \(\.$channel) in \(.applicationName)",
                "Message \(\.$channel) in \(.applicationName)",
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane"
        )
    }
}

import Foundation

/// The Intelligence toggles in Settings. Neither key registers a default, so an unset key reads as on.
public enum TranscriptIntelligenceSettings {
    public static let summarizesNewMessages = "summarizeNewMessages"
    public static let describesImages = "describeImagesForVoiceOver"

    public static func isOn(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

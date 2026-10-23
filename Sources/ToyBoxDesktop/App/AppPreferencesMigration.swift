import Foundation

enum AppPreferencesMigration {
    static let bundleIdentifier = "dev.toybox.desktop"
    static let legacyDomain = "dev.toybox.channels.mac"
    static let completionKey = "didImportLegacyPreferences"
    static let notificationOptInKey = "legacyNotificationOptInPending"

    static func run(
        isSnapshot: Bool,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard,
        sourceDomain: String = AppPreferencesMigration.legacyDomain,
        destinationDomain: String = AppPreferencesMigration.bundleIdentifier
    ) {
        guard bundleIdentifier == Self.bundleIdentifier, !isSnapshot else { return }
        var destination = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        guard destination[completionKey] as? Bool != true else { return }
        let source = defaults.persistentDomain(forName: sourceDomain) ?? [:]
        let importedNotificationOptIn = destination["notificationsEnabled"] == nil
            && source["notificationsEnabled"] as? Bool == true
        for (key, value) in source where destination[key] == nil {
            destination[key] = value
        }
        if importedNotificationOptIn, destination[notificationOptInKey] == nil {
            destination[notificationOptInKey] = true
        }
        destination[completionKey] = true
        defaults.setPersistentDomain(destination, forName: destinationDomain)
    }

    static func takeNotificationOptIn(
        isSnapshot: Bool,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard bundleIdentifier == Self.bundleIdentifier, !isSnapshot,
              defaults.bool(forKey: notificationOptInKey) else { return false }
        defaults.removeObject(forKey: notificationOptInKey)
        return defaults.bool(forKey: "notificationsEnabled")
    }
}

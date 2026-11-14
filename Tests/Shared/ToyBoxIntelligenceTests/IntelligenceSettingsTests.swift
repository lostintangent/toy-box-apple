import ToyBoxIntelligence
import Foundation
import Testing

struct IntelligenceSettingsTests {
    @Test func preferencesDefaultOnUntilTurnedOffWithoutWritingADefault() throws {
        let key = IntelligenceSettings.summarizesNewMessages
        let suite = "IntelligenceSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(IntelligenceSettings.isOn(key, defaults: defaults))
        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.volatileDomain(forName: UserDefaults.registrationDomain)[key] == nil)
        defaults.set(false, forKey: key)
        #expect(!IntelligenceSettings.isOn(key, defaults: defaults))
        defaults.set("invalid", forKey: key)
        #expect(IntelligenceSettings.isOn(key, defaults: defaults))
    }
}

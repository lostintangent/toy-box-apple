import ToyBoxIntelligence
import Foundation
import Testing

struct IntelligenceSettingsTests {
    @Test func keysPreserveExistingPreferences() {
        #expect(IntelligenceSettings.summarizesNewMessages == "summarizeNewMessages")
        #expect(IntelligenceSettings.describesImages == "describeImagesForVoiceOver")
    }

    @Test(arguments: [IntelligenceSettings.summarizesNewMessages, IntelligenceSettings.describesImages])
    func preferencesDefaultOnWithoutRegisteringOrOverwritingValues(key: String) throws {
        let suite = "IntelligenceSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(defaults.object(forKey: key) == nil)
        #expect(IntelligenceSettings.isOn(key, defaults: defaults))
        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.volatileDomain(forName: UserDefaults.registrationDomain)[key] == nil)

        defaults.set(false, forKey: key)
        #expect(!IntelligenceSettings.isOn(key, defaults: defaults))
        defaults.set(true, forKey: key)
        #expect(IntelligenceSettings.isOn(key, defaults: defaults))
        defaults.set("invalid", forKey: key)
        #expect(IntelligenceSettings.isOn(key, defaults: defaults))
        #expect(defaults.string(forKey: key) == "invalid")
        defaults.removeObject(forKey: key)
        #expect(IntelligenceSettings.isOn(key, defaults: defaults))
        #expect(defaults.object(forKey: key) == nil)
    }
}

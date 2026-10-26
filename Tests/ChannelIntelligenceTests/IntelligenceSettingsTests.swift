import ChannelIntelligence
import Foundation
import Testing

struct IntelligenceSettingsTests {
    @Test func keysPreserveExistingPreferences() {
        #expect(TranscriptIntelligenceSettings.summarizesNewMessages == "summarizeNewMessages")
        #expect(TranscriptIntelligenceSettings.describesImages == "describeImagesForVoiceOver")
    }

    @Test(arguments: [TranscriptIntelligenceSettings.summarizesNewMessages, TranscriptIntelligenceSettings.describesImages])
    func preferencesDefaultOnWithoutRegisteringOrOverwritingValues(key: String) throws {
        let suite = "IntelligenceSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(defaults.object(forKey: key) == nil)
        #expect(TranscriptIntelligenceSettings.isOn(key, defaults: defaults))
        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.volatileDomain(forName: UserDefaults.registrationDomain)[key] == nil)

        defaults.set(false, forKey: key)
        #expect(!TranscriptIntelligenceSettings.isOn(key, defaults: defaults))
        defaults.set(true, forKey: key)
        #expect(TranscriptIntelligenceSettings.isOn(key, defaults: defaults))
        defaults.set("invalid", forKey: key)
        #expect(TranscriptIntelligenceSettings.isOn(key, defaults: defaults))
        #expect(defaults.string(forKey: key) == "invalid")
        defaults.removeObject(forKey: key)
        #expect(TranscriptIntelligenceSettings.isOn(key, defaults: defaults))
        #expect(defaults.object(forKey: key) == nil)
    }
}

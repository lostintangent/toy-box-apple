import Foundation
import Testing
import ToyBoxMobileIntegrations

struct MobilePushRegistrationTests {
    @Test @MainActor func theSelectedServerKeepsItsIDUntilTheServerChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-registration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MobilePushRegistrationStore(directory: directory)
        #expect(store.current == nil)
        let first = try store.select(serverURL: "https://server.test/")
        #expect(UUID(uuidString: first.registrationID) != nil)
        #expect(try store.select(serverURL: "https://server.test/") == first)

        let restored = try MobilePushRegistrationStore(directory: directory)
        #expect(restored.current == first)
        let normalized = try restored.select(serverURL: "https://SERVER.test:443")
        #expect(normalized.registrationID == first.registrationID)
        #expect(normalized.serverURL == "https://SERVER.test:443")
        #expect(try MobilePushRegistrationStore(directory: directory).current == normalized)

        let second = try restored.select(serverURL: "https://other.test/base")
        #expect(second.registrationID != first.registrationID)
        #expect(try restored.select(serverURL: first.serverURL).registrationID != first.registrationID)
        #expect(try restored.select(serverURL: first.serverURL).registrationID != second.registrationID)
    }

    @Test @MainActor func invalidSelectionAndStorageNeverSilentlyReplaceARegistration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-registration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MobilePushRegistrationStore(directory: directory)
        let original = try store.select(serverURL: "https://server.test")
        for server in ["file:///tmp", "https://user@server.test", "https://server.test?token=invalid"] {
            #expect(throws: (any Error).self) { try store.select(serverURL: server) }
            #expect(store.current == original)
        }
        let file = directory.appendingPathComponent(MobilePushRegistrationStore.fileName)
        try Data("invalid".utf8).write(to: file)
        #expect(throws: (any Error).self) { try MobilePushRegistrationStore(directory: directory) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: directory)
        try Data("Not a directory".utf8).write(to: directory)
        #expect(throws: (any Error).self) { try store.select(serverURL: "https://other.test") }
        #expect(store.current == original)
    }
}

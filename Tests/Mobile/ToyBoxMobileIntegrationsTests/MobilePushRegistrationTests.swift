import Foundation
import Testing
import ToyBoxMobileIntegrations

struct MobilePushRegistrationTests {
    @Test @MainActor func eachServerKeepsItsIDThroughAnotherSpellingUntilItIsRemoved() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MobilePushRegistrationStore(directory: directory)
        #expect(store.registrations.isEmpty)
        let first = try store.register(serverURL: "https://server.test/")
        #expect(UUID(uuidString: first.registrationID) != nil)
        #expect(try store.register(serverURL: "https://server.test/") == first)
        let second = try store.register(serverURL: "https://other.test/base")
        #expect(second.registrationID != first.registrationID)

        let restored = try MobilePushRegistrationStore(directory: directory)
        #expect(restored.registrations == [first, second])
        let respelled = try restored.register(serverURL: "https://SERVER.test:443")
        #expect(respelled.registrationID == first.registrationID)
        #expect(respelled.serverURL == "https://SERVER.test:443")
        #expect(restored.registration(for: "https://server.test") == respelled)
        #expect(restored.registration(id: second.registrationID) == second)
        #expect(try MobilePushRegistrationStore(directory: directory).registrations == [respelled, second])

        try restored.remove(registrationID: first.registrationID)
        #expect(restored.registration(for: first.serverURL) == nil)
        let readded = try restored.register(serverURL: first.serverURL)
        #expect(readded.registrationID != first.registrationID, "Adding a server back registers it anew")
        #expect(try MobilePushRegistrationStore(directory: directory).registrations == [second, readded])
    }

    @Test @MainActor func theOneRegistrationFromBeforeSeveralServersStaysFirstWithItsID() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"serverURL":"https://server.test","registrationID":"\#(id)"}"#.utf8)
            .write(to: directory.appendingPathComponent(MobilePushRegistrationStore.fileName))

        let store = try MobilePushRegistrationStore(directory: directory)
        #expect(store.registrations.map(\.registrationID) == [id])
        #expect(try store.register(serverURL: "https://server.test").registrationID == id)
        let other = try store.register(serverURL: "https://other.test")
        #expect(try MobilePushRegistrationStore(directory: directory).registrations.map(\.registrationID)
            == [id, other.registrationID])
    }

    @Test @MainActor func invalidRegistrationAndStorageNeverSilentlyReplaceARegistration() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MobilePushRegistrationStore(directory: directory)
        let original = try store.register(serverURL: "https://server.test")
        for server in ["file:///tmp", "https://user@server.test", "https://server.test?token=invalid"] {
            #expect(throws: (any Error).self) { try store.register(serverURL: server) }
            #expect(store.registrations == [original])
        }
        let file = directory.appendingPathComponent(MobilePushRegistrationStore.fileName)
        for invalid in ["invalid", #"[{"serverURL":"https://server.test","registrationID":"not-a-uuid"}]"#,
                        #"[{"serverURL":"file:///tmp","registrationID":"\#(UUID().uuidString)"}]"#] {
            try Data(invalid.utf8).write(to: file)
            #expect(throws: (any Error).self) { try MobilePushRegistrationStore(directory: directory) }
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: directory)
        try Data("Not a directory".utf8).write(to: directory)
        #expect(throws: (any Error).self) { try store.register(serverURL: "https://other.test") }
        #expect(store.registrations == [original])
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tbm-registration-\(UUID())")
    }
}

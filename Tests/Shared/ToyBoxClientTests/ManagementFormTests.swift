import ToyBoxKit
import Foundation
import Testing
@testable import ToyBoxClient

struct ManagementFormTests {
    private let model = ModelConfiguration(provider: "test", name: "test")

    private func sentBody(_ submit: (ChannelAPI) async throws -> Void) async throws -> JSONValue {
        let channel = testState().channel
        let mock = MockTransport { request, _ in
            request.url?.path.contains("/members") == true
                ? try .json(ChannelAgent(id: "ada", name: "Ada")) : try .json(channel)
        }
        try await submit(try mock.api())
        #expect(mock.requests.count == 1)
        return try JSONDecoder().decode(JSONValue.self, from: requestBody(try #require(mock.requests.first)))
    }

    @Test(arguments: ["", "  ", "  A purpose  "])
    func aNewChannelSendsTrimmedValuesAndOmitsWhatsEmpty(purpose: String) async throws {
        var form = ChannelForm()
        form.name = "  Discussion  "
        form.purpose = purpose
        form.directory = "  "
        form.model = model
        let body = try await sentBody { _ = try await form.submit(to: $0) }
        var expected: [String: JSONValue] = [
            "name": .string("Discussion"),
            "model": .object(["provider": .string("test"), "name": .string("test")])
        ]
        let trimmed = purpose.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { expected["purpose"] = .string(trimmed) }
        #expect(body == .object(expected))
    }

    @Test func anEditSendsOnlyWhatChangedAndClearsAnEmptiedPurpose() async throws {
        var form = ChannelForm(ChannelDetails(Channel(
            id: "test", name: "Discussion", purpose: "Keep", directory: "/srv/discussion",
            model: model, updatedAt: "2026-10-26T12:00:00Z")))
        #expect(!form.isSubmittable)
        form.purpose = "  "
        #expect(form.isSubmittable)
        let body = try await sentBody { _ = try await form.submit(to: $0) }
        #expect(body == .object(["purpose": .null]))
    }

    @Test func anAgentEditClearsItsModelOverrideToInherit() async throws {
        var form = MemberForm(ChannelAgent(id: "ada", name: "Ada", role: "Builds", model: model))
        form.model = nil
        form.role = " Builds "
        let body = try await sentBody { _ = try await form.submit(to: $0, channelId: "test") }
        #expect(body == .object(["model": .null]))
    }
}

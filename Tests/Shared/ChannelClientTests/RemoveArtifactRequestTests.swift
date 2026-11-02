import Foundation
import Testing
@testable import ChannelClient

struct RemoveArtifactRequestTests {
    @Test func removalDeletesTheEncodedArtifactAndAcceptsNoContent() async throws {
        let mock = MockTransport { _, _ in MockResponse(status: 204) }
        let api = try mock.api()
        try await api.removeArtifact(channelId: "test", artifactId: "machine:/demo/Plan.md")
        #expect(mock.requests.count == 1)
        let request = try #require(mock.requests.first)
        #expect(request.httpMethod == "DELETE")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/api/v1/channels/test/artifacts/machine%3A%2Fdemo%2FPlan.md")
    }

    @Test func removingAnUnsharedArtifactSurfacesTheServerNotFound() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(status: 404, body: Data(#"{"error":"Artifact is not shared."}"#.utf8))
        }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.http(status: 404, message: "Artifact is not shared.")) {
            try await api.removeArtifact(channelId: "test", artifactId: "machine:/demo/Plan.md")
        }
        #expect(mock.requests.count == 1)
    }
}

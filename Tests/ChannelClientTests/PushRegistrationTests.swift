import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

struct PushRegistrationTests {
    @Test func registrationAndSubscriptionWritesUseTheDocumentedRoutesAndUnixStartTime() async throws {
        let mock = MockTransport { _, _ in MockResponse(status: 204) }
        let base = try mock.api()
        let api = try ChannelAPI(baseURL: base.baseURL.appendingPathComponent("prefix"), session: base.session)
        let id = UUID().uuidString
        let registration = PushRegistration(token: "abcd", environment: .sandbox)
        let activity = PushSubscription(token: "cdef", startedAt: Date(timeIntervalSince1970: 1793086200))
        try await api.register(registrationID: id, registration)
        try await api.unregister(registrationID: id)
        try await api.subscribe(topic: "studio-demo", registrationID: id, activity)
        try await api.unsubscribe(topic: "studio-demo", registrationID: id)
        let requests = mock.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "DELETE", "PUT", "DELETE"])
        #expect(requests.map { $0.url?.path } == [
            "/prefix/api/v1/push/\(id)", "/prefix/api/v1/push/\(id)",
            "/prefix/api/v1/push/\(id)/topics/studio-demo",
            "/prefix/api/v1/push/\(id)/topics/studio-demo",
        ])
        #expect(try JSONDecoder().decode(PushRegistration.self, from: requestBody(requests[0])) == registration)
        let registrationJSON = try #require(JSONSerialization.jsonObject(with: requestBody(requests[0])) as? [String: Any])
        #expect(Set(registrationJSON.keys) == ["token", "environment"])
        let activityData = try requestBody(requests[2])
        #expect(try JSONDecoder().decode(PushSubscription.self, from: activityData) == activity)
        let activityJSON = try #require(JSONSerialization.jsonObject(with: activityData) as? [String: Any])
        #expect(activityJSON["startedAt"] as? Double == 1793086200)
        #expect(Set(activityJSON.keys) == ["token", "startedAt"])
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requests[1].httpBody == nil && requests[1].httpBodyStream == nil)
        #expect(requests[3].httpBody == nil && requests[3].httpBodyStream == nil)
    }

    @Test(arguments: [201, 204])
    func registrationCreationRemainsDistinctFromAnExistingRegistration(status: Int) async throws {
        let mock = MockTransport { _, _ in MockResponse(status: status) }
        let created = try await mock.api().register(registrationID: UUID().uuidString,
                                                    .init(token: "abcd", environment: .sandbox))
        #expect(created == (status == 201))
    }

    @Test func notificationTopicsSendAnEmptyBodyWithoutAnyRouteIdentityOrEnvironment() async throws {
        let mock = MockTransport { _, _ in MockResponse(status: 204) }
        try await mock.api().subscribe(topic: "requests", registrationID: UUID().uuidString, .init())
        let json = try #require(JSONSerialization.jsonObject(with: requestBody(mock.requests[0])) as? [String: Any])
        #expect(json.isEmpty)
    }

    @Test(arguments: [404, 422, 500], [false, true])
    func rejectedPushWritesNeverAutomaticallyRetry(status: Int, subscription: Bool) async throws {
        let mock = MockTransport { _, _ in MockResponse(status: status, body: Data(#"{"error":"Rejected"}"#.utf8)) }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.http(status: status, message: "Rejected")) {
            if subscription {
                try await api.subscribe(topic: "requests", registrationID: UUID().uuidString, .init())
            } else {
                try await api.register(registrationID: UUID().uuidString, .init(token: "abcd", environment: .sandbox))
            }
        }
        #expect(mock.requests.count == 1)
    }
}

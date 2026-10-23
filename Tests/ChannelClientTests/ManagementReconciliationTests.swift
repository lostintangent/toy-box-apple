import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

struct ManagementReconciliationTests {
    enum Write: CaseIterable, Sendable {
        case createChannel, editChannel, deleteChannel, createMember, editMember, removeMember, runRoutine, deleteRoutine

        func perform(using api: ChannelAPI) async throws {
            switch self {
            case .createChannel:
                _ = try await api.createChannel(.init(name: "Test", model: testState().channel.model))
            case .editChannel:
                _ = try await api.editChannel(id: "test", changes: .init(name: "Edited"))
            case .deleteChannel: try await api.deleteChannel(id: "test")
            case .createMember:
                _ = try await api.createMember(channelId: "test", input: .init(name: "Ada"))
            case .editMember:
                _ = try await api.editMember(channelId: "test", agentId: "member", changes: .init(model: .clear))
            case .removeMember: try await api.removeMember(channelId: "test", agentId: "member")
            case .runRoutine: try await api.runRoutine(channelId: "test", routineId: "daily")
            case .deleteRoutine: try await api.deleteRoutine(channelId: "test", routineId: "daily")
            }
        }
    }

    @Test func clearOverrideSendsNullAndReceiptAndEventRemoveTheModel() async throws {
        let memberData = Data(#"{"id":"member","name":"Ada","channelId":"test"}"#.utf8)
        let mock = MockTransport { _, _ in
            MockResponse(body: Data(#"{"version":1,"member":{"id":"member","name":"Ada","channelId":"test"}}"#.utf8))
        }
        let api = try mock.api()
        let receipt = try await api.editMember(channelId: "test", agentId: "member", changes: .init(model: .clear))
        let request = try #require(mock.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/v1/channels/test/members/member")
        let body = try JSONDecoder().decode(JSONValue.self, from: requestBody(request))
        #expect(body == .object(["model": .null]))
        #expect(receipt.model == nil)
        var state = testState()
        state.members = [ChannelAgent(id: "member", name: "Ada", channelId: "test",
                                      model: .init(provider: "copilot", name: "explicit"))]
        let cleared = try JSONDecoder().decode(ChannelMember.self, from: memberData)
        let reduced = reduceChannelState(state, .init(type: "member", revision: 1, member: cleared))
        #expect(reduced.members.first?.model == nil)
        #expect(reduced.members.first?.id == "member")
    }

    @Test(arguments: [500, 422])
    func everyManagementWriteIsSingleAttemptAndPreservesTheServerError(status: Int) async throws {
        for write in Write.allCases {
            let mock = MockTransport { _, _ in
                MockResponse(status: status, body: Data(#"{"error":"Unable to change Channel."}"#.utf8))
            }
            let api = try mock.api()
            await #expect(throws: ChannelAPIError.http(status: status, message: "Unable to change Channel.")) {
                try await write.perform(using: api)
            }
            #expect(mock.requests.count == 1)
        }
    }

    @Test func explicitCrossProviderAssignmentStillSurfacesTheDomainRejection() async throws {
        let message = "A member's provider cannot change without losing its session history."
        let mock = MockTransport { _, _ in
            try .json(["error": message], status: 422)
        }
        let api = try mock.api()
        await #expect(throws: ChannelAPIError.http(status: 422, message: message)) {
            try await api.editMember(channelId: "test", agentId: "member",
                                     changes: .init(model: .set(.init(provider: "claude", name: "sonnet"))))
        }
        #expect(mock.requests.count == 1)
        let request = try #require(mock.requests.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: requestBody(request))
        #expect(body == .object(["model": .object(["provider": .string("claude"), "name": .string("sonnet")])]))
    }

    @Test @MainActor func snapshotReadHasNoCursorAndClosesItsStream() async throws {
        let snapshot = testState(revision: 9)
        let mock = MockTransport { _, _ in try .stream([.init(type: "snapshot", state: snapshot)]) }
        let result = try await mock.api().snapshot(channelId: "test")
        #expect(result == snapshot)
        #expect(mock.requests.first?.url?.query == nil)
        #expect(mock.requests.first?.value(forHTTPHeaderField: "Last-Event-ID") == nil)
        try await eventually { mock.stops == 1 }
    }

    @Test func snapshotReadRejectsMissingMismatchedAndNonSnapshotState() async throws {
        var other = testState()
        other.channel.id = "other"
        let invalid: [ChannelObservationEvent] = [
            .init(type: "snapshot"),
            .init(type: "snapshot", state: other),
            .init(type: "resumed", presence: [:])
        ]
        for event in invalid {
            let mock = MockTransport { _, _ in try .stream([event]) }
            let api = try mock.api()
            await #expect(throws: ChannelAPIError.self) {
                try await api.snapshot(channelId: "test")
            }
            #expect(mock.requests.count == 1)
        }
        let empty = MockTransport { _, _ in try .stream([], keepOpen: false) }
        let api = try empty.api()
        await #expect(throws: ChannelAPIError.streamEnded) {
            try await api.snapshot(channelId: "test")
        }
    }

    @Test(arguments: [Write.deleteChannel, .removeMember, .deleteRoutine])
    @MainActor func committedDeletionWith500ReconcilesWithoutAnotherWrite(write: Write) async throws {
        var old = testState(revision: 5, messages: [testMessage(1), testMessage(2)])
        old.channel.seenThrough = 1
        old.members = [ChannelAgent(id: "member", name: "Ada", channelId: "test")]
        old.routines = [.init(id: "daily", title: "Review", schedule: "0 9 * * *", prompt: "Review")]
        let initial = old
        var next = old
        next.revision = 6
        if write == .removeMember { next.members = [] }
        if write == .deleteRoutine { next.routines = [] }
        let updated = next
        let committed = Mutex(false)
        let mock = MockTransport { request, _ in
            if request.httpMethod == "DELETE" {
                committed.withLock { $0 = true }
                return MockResponse(status: 500, body: Data(#"{"error":"Unable to delete."}"#.utf8))
            }
            let didCommit = committed.withLock { $0 }
            if request.url?.path == "/api/v1/channels" {
                let present = !(didCommit && write == .deleteChannel)
                let state = didCommit ? updated : initial
                return try .json(ChannelCatalog(lead: testLeadProfile, channels: present ? [state.channel] : [],
                                                members: present ? state.members : []))
            }
            if request.url?.query != nil {
                return try .stream([.init(type: "resumed", presence: [:])])
            }
            return try .stream([.init(type: "snapshot", state: didCommit ? updated : initial)])
        }
        let api = try mock.api()
        let catalog = ChannelCatalogStore(api: api)
        let detail = catalog.channel(id: "test")
        detail.connect()
        defer { detail.disconnect() }
        try await eventually { detail.phase.isLive }
        await #expect(throws: ChannelAPIError.http(status: 500, message: "Unable to delete.")) {
            try await write.perform(using: api)
        }
        let review = try await catalog.reconcileManagementWrite(channelId: "test")
        #expect(review.channelWasDeleted == (write == .deleteChannel))
        if write == .deleteChannel {
            #expect(review.state == nil)
            #expect(catalog.channels.isEmpty)
            #expect(detail.phase == .deleted)
        } else {
            #expect(review.state == updated)
            #expect(detail.state == updated)
            #expect(detail.unreadAfter == 1)
            try await eventually { detail.phase.isLive }
            let snapshots = mock.requests.filter { $0.url?.path == "/api/v1/channels/test" && $0.url?.query == nil }
            #expect(snapshots.count == 2)
            #expect(snapshots.allSatisfy { $0.value(forHTTPHeaderField: "Last-Event-ID") == nil })
        }
        #expect(mock.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
        #expect(catalog.error == nil)
        #expect(catalog.failure == nil)
    }

    @Test @MainActor func uncertainCreateReturnsTheCatalogWithoutGuessingOrReposting() async throws {
        var created = testState().channel
        created.id = "new-id"
        let latest = ChannelCatalog(lead: testLeadProfile, channels: [created])
        let mock = MockTransport { request, _ in
            if request.httpMethod == "POST" {
                return MockResponse(status: 500, body: Data(#"{"error":"Unable to create."}"#.utf8))
            }
            return try .json(latest)
        }
        let api = try mock.api()
        let catalog = ChannelCatalogStore(api: api)
        await #expect(throws: ChannelAPIError.http(status: 500, message: "Unable to create.")) {
            try await api.createChannel(.init(name: "Test", model: created.model))
        }
        let review = try await catalog.reconcileManagementWrite()
        #expect(review.catalog == latest)
        #expect(review.channelId == nil)
        #expect(review.state == nil)
        #expect(!review.channelWasDeleted)
        #expect(catalog.channels == latest.channels)
        #expect(mock.requests.map(\.httpMethod) == ["POST", "GET"])
    }

    @Test @MainActor func failedReconciliationDoesNotReturnCachedStateOrRetry() async throws {
        let initial = testState(revision: 5)
        let mock = MockTransport { request, count in
            if count == 1 { return try .stream([.init(type: "snapshot", state: initial)]) }
            if request.url?.path == "/api/v1/channels" {
                return try .json(ChannelCatalog(lead: testLeadProfile, channels: [initial.channel]))
            }
            return MockResponse(status: 500, body: Data(#"{"error":"Unavailable."}"#.utf8))
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let detail = catalog.channel(id: "test")
        detail.connect()
        defer { detail.disconnect() }
        try await eventually { detail.phase.isLive }
        await #expect(throws: ChannelAPIError.self) {
            try await catalog.reconcileManagementWrite(channelId: "test")
        }
        #expect(catalog.error != nil)
        #expect(!catalog.isLoading)
        #expect(catalog.channels.isEmpty)
        #expect(detail.state == initial)
        #expect(detail.phase.isLive)
        #expect(mock.requests.count == 3)
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test(arguments: [401, 403, 503], [true, false])
    @MainActor func reconciliationRetainsTypedFailuresAndClearsThemOnRecovery(
        status: Int, failsDuringDetail: Bool
    ) async throws {
        let initial = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel], working: ["test"])
        let recovered = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])
        let message = failsDuringDetail
            ? HTTPURLResponse.localizedString(forStatusCode: status) : "Reconciliation unavailable."
        let expected = ChannelAPIError.http(status: status, message: message)
        let mock = MockTransport { request, count in
            if count == 1 { return try .json(initial) }
            if (count == 2 && !failsDuringDetail) || request.url?.path != "/api/v1/channels" {
                return MockResponse(status: status, body: Data(#"{"error":"Reconciliation unavailable."}"#.utf8))
            }
            return try .json(recovered)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        await catalog.refresh()
        let refreshedAt = catalog.lastRefreshedAt
        await #expect(throws: expected) {
            try await catalog.reconcileManagementWrite(channelId: "test")
        }
        #expect(catalog.failure as? ChannelAPIError == expected)
        #expect(catalog.error == expected.localizedDescription)
        #expect(catalog.state == initial)
        #expect(catalog.working == ["test"])
        #expect(catalog.lastRefreshedAt == refreshedAt)
        #expect(!catalog.isLoading)
        let review = try await catalog.reconcileManagementWrite()
        #expect(review.catalog == recovered)
        #expect(catalog.failure == nil)
        #expect(catalog.error == nil)
        #expect(catalog.state == recovered)
        #expect(catalog.working.isEmpty)
        #expect(mock.requests.count == (failsDuringDetail ? 4 : 3))
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test(arguments: [true, false])
    @MainActor func detail404RequiresCatalogConfirmationBeforeDeclaringDeletion(channelWasDeleted: Bool) async throws {
        let initial = testState()
        let mock = MockTransport { request, count in
            if request.url?.path == "/api/v1/channels" {
                return try .json(ChannelCatalog(lead: testLeadProfile,
                                                channels: count == 1 || !channelWasDeleted ? [initial.channel] : []))
            }
            return MockResponse(status: 404)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let detail = catalog.channel(id: "test")
        if channelWasDeleted {
            let review = try await catalog.reconcileManagementWrite(channelId: "test")
            #expect(review.channelWasDeleted)
            #expect(review.catalog.channels.isEmpty)
            #expect(detail.phase == .deleted)
        } else {
            await #expect(throws: ChannelAPIError.self) {
                try await catalog.reconcileManagementWrite(channelId: "test")
            }
            #expect(detail.phase != .deleted)
            #expect(catalog.error != nil)
        }
        #expect(mock.requests.count == 3)
        #expect(mock.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test @MainActor func aFreshSnapshotCannotRollBackANewerLiveRevision() async throws {
        let live = testState(revision: 12, messages: [testMessage(1), testMessage(2)])
        let earlier = testState(revision: 10, messages: [testMessage(1)])
        let mock = MockTransport { request, count in
            if request.url?.path == "/api/v1/channels" {
                return try .json(ChannelCatalog(lead: testLeadProfile, channels: [live.channel]))
            }
            return try .stream([.init(type: "snapshot", state: count == 1 ? live : earlier)])
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let detail = catalog.channel(id: "test")
        detail.connect()
        defer { detail.disconnect() }
        try await eventually { detail.phase.isLive }
        let review = try await catalog.reconcileManagementWrite(channelId: "test")
        #expect(review.state == live)
        #expect(detail.state == live)
        #expect(detail.phase.isLive)
        #expect(mock.requests.count == 3)
    }

    @Test @MainActor func concurrentReconciliationIsRejectedWithoutAnotherRequest() async throws {
        let mock = MockTransport { _, _ in
            var pending = try MockResponse.json(ChannelCatalog(lead: testLeadProfile))
            pending.keepOpen = true
            return pending
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let first = Task { try await catalog.reconcileManagementWrite() }
        try await eventually { mock.requests.count == 1 }
        await #expect(throws: ChannelAPIError.self) {
            try await catalog.reconcileManagementWrite(channelId: "test")
        }
        #expect(mock.requests.count == 1)
        #expect(catalog.isLoading)
        first.cancel()
        await #expect(throws: (any Error).self) { try await first.value }
        #expect(!catalog.isLoading)
    }

    @Test @MainActor func aSupersededPollCannotPublishItsErrorOverReconciliation() async throws {
        let latest = ChannelCatalog(lead: testLeadProfile, channels: [testState().channel])
        let mock = MockTransport { _, count in
            if count == 1 {
                var pending = try MockResponse.json(ChannelCatalog(lead: testLeadProfile))
                pending.keepOpen = true
                return pending
            }
            return try .json(latest)
        }
        let catalog = ChannelCatalogStore(api: try mock.api())
        let poll = Task { await catalog.refresh() }
        try await eventually { mock.requests.count == 1 }
        let review = try await catalog.reconcileManagementWrite()
        poll.cancel()
        await poll.value
        #expect(review.catalog == latest)
        #expect(catalog.channels == latest.channels)
        #expect(catalog.error == nil)
        #expect(catalog.failure == nil)
        #expect(!catalog.isLoading)
    }
}

import ToyBoxKit
import Foundation
import Testing
@testable import ToyBoxClient

@MainActor
@Suite("Server providers", .timeLimit(.minutes(1)))
struct ServerProvidersTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func makeStore(_ mock: MockTransport, clock: Clock = Clock()) throws -> ServerProviders {
        ServerProviders(api: try mock.api(), now: { clock.now })
    }

    private func subscriptionRequests(_ mock: MockTransport) -> [String] {
        mock.requests.compactMap { request in
            let path = request.url?.path ?? ""
            guard path.hasPrefix("/api/v1/providers/"), path.hasSuffix("/subscription") else { return nil }
            return String(path.dropFirst("/api/v1/providers/".count).dropLast("/subscription".count))
        }
    }

    @Test func appearDecodesEachProvidersSubscriptionIncludingNullAndDates() async throws {
        let mock = MockTransport { request, _ in
            switch request.url?.path {
            case "/api/v1/providers":
                try .json(ModelProviderList(providers: [
                    .init(id: "copilot", name: "GitHub Copilot", status: .ready, version: "1.0.114", enabled: true),
                    .init(id: "codex", name: "OpenAI Codex", status: .ready, version: "0.170.0", enabled: true),
                    .init(id: "local", name: "Local", status: .ready, enabled: true),
                    .init(id: "gemini", name: "Gemini", status: .signedOut, enabled: true),
                ]))
            case "/api/v1/providers/copilot/subscription":
                try .json(ModelProviderSubscription(plan: "enterprise"))
            case "/api/v1/providers/codex/subscription":
                try .json(ModelProviderSubscription(plan: "pro", limits: [
                    .init(name: "Weekly", usedPercent: 0,
                          resetsAt: Date(timeIntervalSince1970: 1_795_722_169)),
                ]))
            case "/api/v1/providers/local/subscription":
                MockResponse(contentType: "application/json", body: Data("null".utf8))
            default:
                MockResponse(status: 404, body: Data(#"{"error":"Provider not found."}"#.utf8))
            }
        }
        let store = try makeStore(mock)
        await store.appear()
        #expect(store.list.map(\.id) == ["copilot", "codex", "local", "gemini"])
        #expect(store.entries.map(\.usage) == [
            .loaded(.init(plan: "enterprise")),
            .loaded(.init(plan: "pro", limits: [
                .init(name: "Weekly", usedPercent: 0, resetsAt: Date(timeIntervalSince1970: 1_795_722_169)),
            ])),
            .none,
            nil,
        ])
        #expect(Set(subscriptionRequests(mock)) == ["copilot", "codex", "local"])
    }

    @Test func appearReadsEachReadyProviderAtMostOnceAMinuteAndRetrySkipsTheWait() async throws {
        let clock = Clock()
        let mock = MockTransport { request, _ in
            switch request.url?.path {
            case "/api/v1/providers":
                try .json(ModelProviderList(providers: [
                    .init(id: "codex", name: "OpenAI Codex", status: .ready, enabled: true),
                ]))
            case "/api/v1/providers/codex/subscription":
                try .json(ModelProviderSubscription(plan: "pro"))
            default:
                MockResponse(status: 404)
            }
        }
        let store = try makeStore(mock, clock: clock)
        await store.appear()
        await store.appear()
        #expect(mock.requests.filter { $0.url?.path == "/api/v1/providers" }.count == 2)
        #expect(subscriptionRequests(mock) == ["codex"])

        await store.retry("codex")
        #expect(subscriptionRequests(mock) == ["codex", "codex"])

        clock.now += ServerProviders.refreshInterval
        await store.appear()
        #expect(subscriptionRequests(mock) == ["codex", "codex", "codex"])
    }

    @Test func aFailedReadStaysWithItsOwnProvider() async throws {
        let mock = MockTransport { request, _ in
            switch request.url?.path {
            case "/api/v1/providers":
                try .json(ModelProviderList(providers: [
                    .init(id: "codex", name: "OpenAI Codex", status: .ready, enabled: true),
                    .init(id: "claude", name: "Claude Agent", status: .ready, enabled: true),
                    .init(id: "cursor", name: "Cursor", status: .ready, enabled: true),
                ]))
            case "/api/v1/providers/codex/subscription":
                try .json(ModelProviderSubscription(plan: "pro"))
            case "/api/v1/providers/claude/subscription":
                try .json(ModelProviderSubscription(plan: "max", limits: [
                    .init(name: "Weekly", usedPercent: 10),
                ]))
            case "/api/v1/providers/cursor/subscription":
                MockResponse(status: 500, body: Data(#"{"error":"Usage unavailable."}"#.utf8))
            default:
                MockResponse(status: 404)
            }
        }
        let store = try makeStore(mock)
        await store.appear()
        #expect(store.entries.map(\.id) == ["codex", "claude", "cursor"])
        #expect(store.entries.map(\.usage) == [
            .loaded(.init(plan: "pro")),
            .loaded(.init(plan: "max", limits: [.init(name: "Weekly", usedPercent: 10)])),
            .failed("Usage unavailable."),
        ])
    }

    @Test func anUnknownProviderIsNotFound() async throws {
        let mock = MockTransport { _, _ in
            MockResponse(status: 404, body: Data(#"{"error":"Provider not found."}"#.utf8))
        }
        await #expect(throws: ChannelAPIError.http(status: 404, message: "Provider not found.")) {
            try await mock.api().providerSubscription(id: "unknown")
        }
    }
}

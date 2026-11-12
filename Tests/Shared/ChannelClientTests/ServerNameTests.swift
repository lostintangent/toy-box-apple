import ChannelKit
import Foundation
import Synchronization
import Testing
@testable import ChannelClient

@MainActor
@Suite("Server name", .timeLimit(.minutes(1)))
struct ServerNameTests {
    /// What the server answers on `/api/v1/server`, and how it takes a rename. Tests change it as the
    /// server would.
    private final class Server: Sendable {
        struct Answers {
            var id: String? = "studio-id"
            var name: String? = "Studio"
            var accentColor = "#123abc"
            /// Nil predates the route and answers 404.
            var isRouted = true
            /// Answers a read instead of the server, as a failing server would.
            var read: MockResponse?
            /// Answers a rename instead of taking it. A rename that answers nil takes it, then
            /// loses the connection.
            var rename: MockResponse??
            var renames: [String] = []
            /// The computer's name, which an empty rename gives back.
            var computer = "Mac mini"
        }
        let answers = Mutex(Answers())

        func set(_ change: (inout Answers) -> Void) { answers.withLock { change(&$0) } }

        func response(to request: URLRequest) throws -> MockResponse {
            try answers.withLock { answers throws -> MockResponse in
                func info() throws -> MockResponse {
                    try .json(ServerInfo(id: answers.id, name: answers.name, accentColor: answers.accentColor,
                                         release: .init(version: "0.4.0", installedVersion: nil), links: []))
                }
                switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
                case ("GET", "/api/v1/channels"):
                    return try .catalogStream(ChannelCatalog(lead: testLeadProfile))
                case ("GET", "/api/v1/server") where answers.isRouted:
                    return try answers.read ?? info()
                case ("PATCH", "/api/v1/server") where answers.isRouted:
                    let input = try JSONDecoder().decode([String: String].self, from: requestBody(request))
                    let name = try #require(input["name"])
                    answers.renames.append(name)
                    if case .some(.some(let refusal)) = answers.rename { return refusal }
                    answers.name = name.isEmpty ? answers.computer : name
                    if case .some(.none) = answers.rename { throw URLError(.networkConnectionLost) }
                    return try info()
                default:
                    return MockResponse(status: 404)
                }
            }
        }
    }

    private func catalog(_ server: Server, name: String? = nil) throws -> (ChannelCatalogStore, MockTransport) {
        let mock = MockTransport { request, _ in try server.response(to: request) }
        return (ChannelCatalogStore(api: try mock.api(), name: name), mock)
    }

    private func reads(_ mock: MockTransport) -> Int {
        mock.requests.filter { $0.httpMethod == "GET" && $0.url?.path == "/api/v1/server" }.count
    }

    @Test func aReadTakesTheServersNameAndIdentityAndSavesOnlyAChange() async throws {
        let server = Server()
        let (catalog, _) = try catalog(server, name: "Typed")
        var saves = 0
        catalog.onSavedChange = { saves += 1 }

        await catalog.refreshServer()
        #expect(catalog.name == "Studio" && catalog.serverID == "studio-id" && !catalog.needsUpdateToRename)
        #expect(catalog.accentColor == "#123abc", "The accent is kept, though nothing shows it yet.")
        #expect(catalog.saved.name == "Studio" && catalog.saved.id == "studio-id")
        #expect(saves == 1)

        await catalog.refreshServer()
        #expect(saves == 1, "The same answer saves nothing.")

        server.set { $0.read = MockResponse(status: 500) }
        await catalog.refreshServer()
        #expect(catalog.name == "Studio" && saves == 1, "A failed read keeps the last name.")

        server.set { $0.read = nil; $0.name = "Studio 2" }
        await catalog.refreshServer()
        #expect(catalog.name == "Studio 2" && saves == 2)
    }

    @Test func aServerTooOldToHaveANameGoesByItsHost() async throws {
        let server = Server()
        server.set { $0.isRouted = false }
        let (catalog, _) = try catalog(server, name: "Typed")
        let host = ChannelCatalogStore.Saved.name(of: catalog.api.baseURL.absoluteString)

        await catalog.refreshServer()
        #expect(catalog.name == host && catalog.serverID == nil && catalog.needsUpdateToRename)

        server.set { $0.isRouted = true; $0.id = nil; $0.name = nil }
        await catalog.refreshServer()
        #expect(catalog.name == host && catalog.needsUpdateToRename, "0.3.9 answers without a name.")

        server.set { $0.id = "studio-id"; $0.name = "Studio" }
        await catalog.refreshServer()
        #expect(catalog.name == "Studio" && !catalog.needsUpdateToRename)
    }

    @Test func renamingChecksTheLengthTheWayTheServerDoes() async throws {
        let server = Server()
        let (catalog, _) = try catalog(server)
        await catalog.refreshServer()

        let tooLong = String(repeating: "😀", count: 33)
        await #expect(throws: ChannelAPIError.invalidMessage("Name must be 64 characters or fewer.")) {
            try await catalog.rename(to: tooLong)
        }
        #expect(server.answers.withLock { $0.renames }.isEmpty, "A name over the limit is never sent.")

        let longest = String(repeating: "😀", count: 32)
        try await catalog.rename(to: "  \(longest) \n")
        #expect(server.answers.withLock { $0.renames } == [longest])
        #expect(catalog.name == longest)
    }

    @Test func aRefusedRenameThrowsTheServersWords() async throws {
        let server = Server()
        let (catalog, mock) = try catalog(server)
        await catalog.refreshServer()
        server.set { $0.rename = try? .json(["error": "Invalid request."], status: 422) }

        await #expect(throws: ChannelAPIError.http(status: 422, message: "Invalid request.")) {
            try await catalog.rename(to: "Work")
        }
        #expect(catalog.name == "Studio" && reads(mock) == 1, "A refusal never committed, so nothing is read.")
    }

    @Test func aRenameThatMayHaveLandedReadsTheServerBeforeFailing() async throws {
        let server = Server()
        let (catalog, mock) = try catalog(server)
        await catalog.refreshServer()

        server.set { $0.rename = .some(nil) }
        try await catalog.rename(to: "Work")
        #expect(catalog.name == "Work" && reads(mock) == 2, "It took, so the lost answer isn't a failure.")

        try await catalog.rename(to: "")
        #expect(server.answers.withLock { $0.renames } == ["Work", ""])
        #expect(catalog.name == "Mac mini", "Clearing it gives back the computer's name.")

        server.set { $0.rename = MockResponse(status: 500) }
        await #expect(throws: ChannelAPIError.self) { try await catalog.rename(to: "Build") }
        #expect(catalog.name == "Mac mini" && reads(mock) == 4, "It read the server, and the name didn't take.")
    }

    @Test func connectingComingForwardAndRefreshingReadTheServer() async throws {
        let server = Server()
        let (catalog, mock) = try catalog(server)
        catalog.startPolling()
        defer { catalog.stopPolling() }

        try await eventually { catalog.name == "Studio" }
        try await eventually(observing: mock) { reads(mock) == 1 }

        server.set { $0.name = "Renamed elsewhere" }
        catalog.setActive(false)
        catalog.setActive(true)
        try await eventually { catalog.name == "Renamed elsewhere" }
        #expect(reads(mock) == 2)

        server.set { $0.name = "Renamed again" }
        await catalog.refresh()
        try await eventually { catalog.name == "Renamed again" }
        #expect(reads(mock) == 3, "Refresh reopens the stream, which reads the server as every connection does.")
    }

    @Test func aSavedServerIsFoundByItsIdentity() async throws {
        let studio = Server(), mini = Server()
        mini.set { $0.id = "mini-id"; $0.name = "Mini" }
        let catalogs = [try catalog(studio).0, try catalog(mini).0]
        #expect(catalogs.first(identifiedAs: "mini-id") == nil, "Nothing is known until it answers.")

        await catalogs.refreshServers()
        #expect(catalogs.first(identifiedAs: "mini-id") === catalogs[1])
        #expect(catalogs.first(identifiedAs: "other") == nil && catalogs.first(identifiedAs: nil) == nil)
    }
}

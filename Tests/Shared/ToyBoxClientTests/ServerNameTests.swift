import ToyBoxKit
import Foundation
import Synchronization
import Testing
@testable import ToyBoxClient

@MainActor
@Suite("Server name", .timeLimit(.minutes(1)))
struct ServerNameTests {
    /// What the server answers on `/api/v1/server`, and how it takes a rename. Tests change it as the
    /// server would.
    private final class Server: Sendable {
        struct Answers {
            var id = "studio-id"
            var name = "Studio"
            var accentColor = "#123abc"
            /// Answers a read instead of the server, as a failing server would.
            var read: MockResponse?
            /// Answers a rename instead of taking it.
            var rename: MockResponse?
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
                                         release: .init(version: "0.4.0", installedVersion: nil), peers: []))
                }
                switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
                case ("GET", "/api/v1/channels"):
                    return try .catalogStream(ChannelCatalog(lead: testLeadProfile))
                case ("GET", "/api/v1/server"):
                    return try answers.read ?? info()
                case ("PATCH", "/api/v1/server"):
                    let input = try JSONDecoder().decode([String: String].self, from: requestBody(request))
                    let name = try #require(input["name"])
                    answers.renames.append(name)
                    if let refusal = answers.rename { return refusal }
                    answers.name = name.isEmpty ? answers.computer : name
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

    private let outboxFolder = FileManager.default.temporaryDirectory.appending(path: "tbm-server-name-\(UUID())")

    private func reads(_ mock: MockTransport) -> Int {
        mock.requests.filter { $0.httpMethod == "GET" && $0.url?.path == "/api/v1/server" }.count
    }

    @Test func aReadTakesTheServersNameAndReportsOnlyARename() async throws {
        let server = Server()
        let mock = MockTransport { request, _ in try server.response(to: request) }
        let servers = ChannelServers(mock.address(), savingTo: nil,
                                     session: MockTransport.session(), outbox: ChannelOutbox(folder: outboxFolder),
                                     connections: ChannelConnections(), isActive: false, streamsInBackground: false)
        let catalog = servers.catalogs[0]
        var saves = 0
        servers.onChange = { saves += 1 }

        await catalog.refreshServer()
        #expect(catalog.name == "Studio")
        #expect(catalog.accentColor == "#123abc", "The accent is kept, though nothing shows it yet.")
        #expect(saves == 1)

        await catalog.refreshServer()
        #expect(saves == 1, "The same answer changes nothing.")

        server.set { $0.read = MockResponse(status: 500) }
        await catalog.refreshServer()
        #expect(catalog.name == "Studio" && saves == 1, "A failed read keeps the last name.")

        server.set { $0.read = nil; $0.name = "Studio 2" }
        await catalog.refreshServer()
        #expect(catalog.name == "Studio 2" && saves == 2)
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
        #expect(catalog.name == "Studio" && reads(mock) == 1)
    }

    @Test func aRenameTakesTheServersAnswerAndAnEmptyOneGivesBackTheComputersName() async throws {
        let server = Server()
        let (catalog, mock) = try catalog(server)
        await catalog.refreshServer()

        try await catalog.rename(to: "Work")
        #expect(catalog.name == "Work")
        try await catalog.rename(to: "")
        #expect(server.answers.withLock { $0.renames } == ["Work", ""])
        #expect(catalog.name == "Mac mini" && reads(mock) == 1, "Each answer is the server's name, so nothing is read.")
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

    @Test func theNameFieldRenamesTheServerAndFollowsItsAnswers() async throws {
        let server = Server()
        server.set { $0.name = "Mac mini" }
        let (catalog, _) = try catalog(server)
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually { catalog.phase == .connected && catalog.name == "Mac mini" }
        let field = ServerNameField(catalog)
        #expect(field.text == "Mac mini" && field.isEditable)

        field.text = "Mac mini "
        await field.commit()
        #expect(server.answers.withLock { $0.renames } == [], "A name that only gained spaces didn't change.")
        field.text = "Studio"
        await field.commit()
        #expect(server.answers.withLock { $0.renames } == ["Studio"])
        #expect(catalog.name == "Studio" && field.text == "Studio" && field.failure == nil)
        field.text = ""
        await field.commit()
        #expect(field.text == "Mac mini", "Clearing it gives the server back its computer's name.")

        server.set { $0.name = "Office" }
        await catalog.refreshServer()
        #expect(field.text == "Office", "A rename made elsewhere shows while nothing is typed.")
    }

    @Test func aRenameTheFieldCantMakeKeepsWhatWasTypedAndSaysWhy() async throws {
        let server = Server()
        server.set {
            $0.name = "Mac mini"
            $0.rename = try? .json(["error": "That name is taken."], status: 422)
        }
        let (catalog, _) = try catalog(server)
        catalog.startPolling()
        defer { catalog.stopPolling() }
        try await eventually { catalog.phase == .connected && catalog.name == "Mac mini" }
        let field = ServerNameField(catalog)

        let long = String(repeating: "😀", count: 33)
        field.text = long
        await field.commit()
        #expect(server.answers.withLock { $0.renames } == [], "A name that's too long is refused before sending.")
        #expect(field.text == long)
        #expect(field.failure?.words == "Couldn't rename Mac mini.")
        #expect(field.failure?.reason == "Name must be 64 characters or fewer.")

        field.text = "Studio"
        await field.commit()
        #expect(server.answers.withLock { $0.renames } == ["Studio"])
        #expect(field.text == "Studio" && catalog.name == "Mac mini")
        #expect(field.failure?.reason == "That name is taken.")

        field.text = "Mac mini"
        await field.commit()
        #expect(server.answers.withLock { $0.renames } == ["Studio"] && field.failure == nil,
                "Typing the server's name back sends nothing and clears the failure.")
    }
}

import ChannelKit
import Foundation
import Synchronization
import Testing
import ToyBoxUI
@testable import ChannelClient

@MainActor
@Suite("Server name field")
struct ServerNameFieldTests {
    @Test func aChangedNameRenamesTheServerAndTheFieldFollowsItsAnswers() async throws {
        let server = NameRoute.Server(computerName: "Mac mini")
        let catalog = try await connect(server)
        let field = ServerNameField(catalog)
        #expect(field.text == "Mac mini" && field.isEditable)

        field.text = "Mac mini "
        await field.commit()
        #expect(NameRoute.renames(server) == [], "A name that only gained spaces didn't change.")
        field.text = "Studio"
        await field.commit()
        #expect(NameRoute.renames(server) == ["Studio"])
        #expect(catalog.name == "Studio" && field.text == "Studio" && field.failure == nil)
        field.text = ""
        await field.commit()
        #expect(field.text == "Mac mini", "Clearing it gives the server back its computer's name.")

        NameRoute.rename(server, to: "Office")
        await catalog.refreshServer()
        #expect(field.text == "Office", "A rename made elsewhere shows while nothing is typed.")
    }

    @Test func aRenameThatFailsKeepsWhatWasTypedAndSaysWhy() async throws {
        let server = NameRoute.Server(computerName: "Mac mini", refusal: "That name is taken.")
        let catalog = try await connect(server)
        let field = ServerNameField(catalog)

        let long = String(repeating: "😀", count: 33)
        field.text = long
        await field.commit()
        #expect(NameRoute.renames(server) == [], "A name that's too long is refused before sending.")
        #expect(field.text == long)
        #expect(field.failure?.words == "Couldn't rename Mac mini.")
        #expect(field.failure?.reason == "Name must be 64 characters or fewer.")

        field.text = "Studio"
        await field.commit()
        #expect(NameRoute.renames(server) == ["Studio"])
        #expect(field.text == "Studio" && catalog.name == "Mac mini")
        #expect(field.failure?.reason == "That name is taken.")

        field.text = "Mac mini"
        await field.commit()
        #expect(NameRoute.renames(server) == ["Studio"] && field.failure == nil,
                "Typing the server's name back sends nothing and clears the failure.")
    }

    private func connect(_ server: NameRoute.Server) async throws -> ChannelCatalogStore {
        NameRoute.servers.withLock { $0[server.host] = server }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NameRoute.self]
        let api = try ChannelAPI(serverURL: "http://\(server.host)", session: URLSession(configuration: configuration))
        let catalog = ChannelCatalogStore(api: api)
        await catalog.refresh()
        await catalog.refreshServer()
        try #require(catalog.phase == .connected)
        return catalog
    }
}

/// A server's catalog and its `/api/v1/server`, which renames it or refuses with its own words.
private final class NameRoute: URLProtocol, @unchecked Sendable {
    struct Server: Sendable {
        let host = UUID().uuidString.lowercased() + ".example"
        let computerName: String
        var refusal: String?
        var name: String?
        var renames: [String] = []
    }
    static let servers = Mutex<[String: Server]>([:])

    static func renames(_ server: Server) -> [String] { servers.withLock { $0[server.host]?.renames ?? [] } }
    static func rename(_ server: Server, to name: String) { servers.withLock { $0[server.host]?.name = name } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            return client!.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
        let rename = request.httpMethod == "PATCH"
            ? request.httpBody.flatMap(Self.name) ?? request.httpBodyStream.flatMap(Self.name) : nil
        let (status, body) = Self.servers.withLock { servers -> (Int, String) in
            guard var server = servers[host] else { return (404, #"{"error":"Not found."}"#) }
            defer { servers[host] = server }
            switch url.path {
            case "/api/v1/channels":
                return (200, ##"{"channels":[],"members":[],"working":[],"lead":{"name":"Lead","role":"Coordinates the channel.","avatar":{"mark":"M12 3L15 9L21 10L16.5 14.5L18 21L12 18L6 21L7.5 14.5L3 10L9 9Z","color":"#1E3A8A","ink":"#FACC15"}}}"##)
            case "/api/v1/server":
                if let rename {
                    server.renames.append(rename)
                    if let refusal = server.refusal { return (422, #"{"error":"\#(refusal)"}"#) }
                    server.name = rename.isEmpty ? nil : rename
                }
                return (200, ##"{"id":"\##(host)","name":"\##(server.name ?? server.computerName)","accentColor":"#facc15","version":"0.4.0","installedVersion":"0.4.0","links":[]}"##)
            default:
                return (404, #"{"error":"Not found."}"#)
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func name(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["name"]
    }

    private static func name(_ stream: InputStream) -> String? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return name(data)
    }
}

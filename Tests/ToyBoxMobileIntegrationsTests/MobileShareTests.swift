import ChannelClient
import ChannelKit
import Foundation
import ImageIO
import Intents
import Synchronization
import Testing
@testable import ToyBoxMobileIntegrations
import UniformTypeIdentifiers

@MainActor
struct MobileShareTests {
    // MARK: Targets

    @Test func aTargetSurvivesItsConversationIdentifierWhateverItsChannelIsCalled() throws {
        let target = try #require(MobileShareTarget(serverURL: "HTTPS://Toy.Example:443/base/", channelID: "a&b=c+d e"))
        #expect(target.serverURL == "https://toy.example/base")
        #expect(MobileShareTarget(conversationIdentifier: target.conversationIdentifier) == target)
        #expect(MobileShareTarget(conversationIdentifier: "?server=ftp://toy.example&channel=studio") == nil)
        #expect(MobileShareTarget(conversationIdentifier: "?server=https://toy.example&channel=") == nil)
        #expect(MobileShareTarget(conversationIdentifier: "?server=https://toy.example") == nil)
    }

    // MARK: History and suggestions

    @Test func recentsPutTheLatestSendFirstKeepTwentyAndSuggestEachOne() async throws {
        let donor = FakeDonor()
        let (history, directory) = try Self.history(donor)
        defer { try? FileManager.default.removeItem(at: directory) }
        await history.select(serverURL: "https://toy.example").value
        for index in 0..<22 {
            await history.recordSend(serverURL: "https://toy.example", channelID: "c\(index)", name: "C\(index)").value
        }
        await history.recordSend(serverURL: "https://TOY.example/", channelID: "c5", name: "Five").value

        #expect(history.recentChannelIDs == ["c5"] + (6...21).reversed().map { "c\($0)" } + ["c4", "c3", "c2"])
        #expect(donor.deleted == [[Self.identifier("c0")], [Self.identifier("c1")]])
        let last = try #require(donor.donated.last)
        let intent = try #require(last.intent as? INSendMessageIntent)
        #expect(last.direction == .outgoing)
        #expect(last.groupIdentifier == Self.identifier("c5"))
        #expect(intent.conversationIdentifier == Self.identifier("c5"))
        #expect(intent.speakableGroupName?.spokenPhrase == "Five")
        #expect(intent.image(forParameterNamed: \.speakableGroupName) != nil)
        #expect(donor.donated.count == 23)
    }

    @Test func theAppAndTheExtensionShareOneHistoryForOneServer() async throws {
        let donor = FakeDonor()
        let (app, directory) = try Self.history(donor)
        defer { try? FileManager.default.removeItem(at: directory) }
        let share = try MobileShareHistory(directory: directory, donor: donor.donor)
        #expect(share.serverURL == nil)

        await app.select(serverURL: "https://toy.example").value
        await share.recordSend(serverURL: "https://toy.example", channelID: "studio", name: "Studio").value
        await app.recordSend(serverURL: "https://elsewhere.example", channelID: "other", name: "Other").value
        #expect(app.recentChannelIDs == ["studio"])
        #expect(share.serverURL == "https://toy.example")

        await app.select(serverURL: "https://TOY.example/").value
        #expect(share.serverURL == "https://TOY.example/")
        #expect(share.recentChannelIDs == ["studio"])
        #expect(donor.deleted.isEmpty)

        await app.select(serverURL: "https://elsewhere.example").value
        #expect(share.recentChannelIDs.isEmpty)
        #expect(donor.deleted == [[Self.identifier("studio")]])
    }

    @Test func pruningForgetsChannelsTheServerNoLongerLists() async throws {
        let donor = FakeDonor()
        let (history, directory) = try Self.history(donor)
        defer { try? FileManager.default.removeItem(at: directory) }
        await history.select(serverURL: "https://toy.example").value
        for id in ["gone", "kept", "removed"] {
            await history.recordSend(serverURL: "https://toy.example", channelID: id, name: id).value
        }

        await history.prune(serverURL: "https://elsewhere.example", keeping: []).value
        #expect(history.recentChannelIDs == ["removed", "kept", "gone"])
        await history.prune(serverURL: "https://toy.example/", keeping: ["kept"]).value
        #expect(history.recentChannelIDs == ["kept"])
        #expect(donor.deleted == [[Self.identifier("removed"), Self.identifier("gone")]])
        await history.prune(serverURL: "https://toy.example", keeping: ["kept"]).value
        #expect(donor.deleted.count == 1)
    }

    // MARK: Content

    @Test func imagesArePreparedOneByOneUpToTenWithSmallThumbnails() async throws {
        let png = try Self.png(width: 900, height: 600)
        var providers: [NSItemProvider] = []
        for index in 0..<12 { providers.append(Self.provider(png, type: .png, name: index == 0 ? "Screenshot.png" : nil)) }
        let content = try await MobileShareContent.load(providers, title: "Ignored")
        guard case .images(let images) = content else { Issue.record("Expected images"); return }

        #expect(images.count == 10)
        #expect(images.map(\.attachment.name).prefix(3) == ["Screenshot.png", "Image 2.png", "Image 3.png"])
        #expect(images.allSatisfy { $0.attachment.mimeType == "image/png" })
        #expect(images.first?.attachment.base64 == png.base64EncodedString())
        #expect(images.first.map { [$0.thumbnail.width, $0.thumbnail.height] } == [300, 200])
        #expect(content.message(note: "  Look  ") == "Look")
        #expect(content.link == nil)
    }

    @Test func imagesComeOutWithinTheExtensionsSmallerLimits() async throws {
        let large = try Self.png(width: 4_000, height: 3_000)
        let heavy = try Self.png(width: 1_000, height: 1_000, noise: true)
        #expect(heavy.count > MobileShareContent.imageBytes && heavy.count < 5_000_000)
        let content = try await MobileShareContent.load([Self.provider(large, type: .png),
                                                         Self.provider(heavy, type: .png)], title: nil)
        guard case .images(let images) = content else { Issue.record("Expected images"); return }

        #expect(images.map(\.attachment.name) == ["Image 1.jpg", "Image 2.jpg"])
        var sizes: [[Int]] = []
        for image in images {
            let data = try #require(image.attachment.base64.flatMap { Data(base64Encoded: $0) })
            #expect(image.attachment.mimeType == "image/jpeg")
            #expect(data.count <= MobileShareContent.imageBytes)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            sizes.append([kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight].compactMap { properties[$0] as? Int })
        }
        #expect(sizes.first == [MobileShareContent.imageDimension, 1_536])
        #expect(sizes.last.map { $0.count == 2 && $0.allSatisfy { $0 <= 1_000 } } == true)
    }

    @Test func aWebPageBecomesItsLinkAfterTheNote() async throws {
        let page = try #require(URL(string: "https://example.com/story?id=4"))
        let content = try await MobileShareContent.load([NSItemProvider(object: page as NSURL)], title: "  A Story \n")

        #expect(content.link == MobileShareLink(url: page, title: "A Story"))
        #expect(content.link?.host == "example.com")
        #expect(content.attachments.isEmpty)
        #expect(content.message(note: " \n") == "https://example.com/story?id=4")
        #expect(content.message(note: " Worth reading ") == "Worth reading\n\nhttps://example.com/story?id=4")
        let untitled = try await MobileShareContent.load([NSItemProvider(object: page as NSURL)], title: " ")
        #expect(untitled.link?.title == nil)
    }

    @Test func textFilesAndUnreadableImagesAreRefused() async throws {
        let file = URL(fileURLWithPath: "/tmp/notes.txt")
        await #expect(throws: MobileShareContent.Failure.unsupported) {
            try await MobileShareContent.load([NSItemProvider(object: "Just text" as NSString),
                                               NSItemProvider(object: file as NSURL)], title: nil)
        }
        await #expect(throws: (any Error).self) {
            try await MobileShareContent.load([Self.provider(Data("not a picture".utf8), type: .png)], title: nil)
        }
    }

    // MARK: Session

    @Test func sendAgainRepeatsTheSameLockedAttemptAndThenRemembersTheChannel() async throws {
        let fixture = try ShareHTTPFixture(posts: [.fail(.networkConnectionLost), .accept])
        let donor = FakeDonor()
        let (session, directory) = try await Self.session(fixture, donor: donor)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.choose(Self.studio)
        session.note = "Look"

        await session.send()
        #expect(session.phase == .unconfirmed)
        #expect(session.canSend)
        session.note = "Changed"

        await session.send()
        #expect(session.phase == .sent)
        #expect(!session.canSend)
        let posts = fixture.posts
        #expect(posts.count == 2)
        #expect(Set(posts.map(\.id)).count == 1)
        #expect(posts.allSatisfy { $0.content == "Look\n\nhttps://example.com/story" })
        #expect(session.notice == nil)
        let history = try MobileShareHistory(directory: directory, donor: donor.donor)
        #expect(history.recentChannelIDs == ["studio"])
        #expect(donor.donated.count == 1)
    }

    @Test func anOfflineSendSaysSoAndKeepsItsAttempt() async throws {
        let fixture = try ShareHTTPFixture(posts: [.fail(.notConnectedToInternet), .accept])
        let (session, directory) = try await Self.session(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.choose(Self.studio)

        await session.send()
        #expect(session.phase == .offline)
        #expect(session.isLocked)
        session.choose(Self.channel("other", "Other"))
        #expect(session.target?.id == "studio")
        await session.send()
        #expect(session.phase == .sent)
        #expect(Set(fixture.posts.map(\.id)).count == 1)
    }

    @Test func aRefusalUnlocksTheMessageAndTheNextSendIsANewAttempt() async throws {
        let fixture = try ShareHTTPFixture(posts: [.status(422, "Attachments are limited to 10."), .accept])
        let (session, directory) = try await Self.session(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.choose(Self.studio)

        await session.send()
        #expect(session.phase == .composing)
        #expect(session.notice == "Attachments are limited to 10.")
        session.note = "Edited"
        #expect(session.note == "Edited")
        await session.send()
        #expect(session.phase == .sent)
        let posts = fixture.posts
        #expect(posts.count == 2)
        #expect(posts.first?.id != posts.last?.id)
        #expect(posts.last?.content == "Edited\n\nhttps://example.com/story")
    }

    @Test func aDeletedChannelAsksForAnotherOne() async throws {
        let fixture = try ShareHTTPFixture(posts: [.status(404, "Channel not found."), .accept])
        let (session, directory) = try await Self.session(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.choose(Self.studio)
        let catalogReads = fixture.catalogReads

        await session.send()
        #expect(session.phase == .composing)
        #expect(session.target == nil)
        #expect(session.notice == "Studio no longer exists. Choose another channel.")
        #expect(fixture.catalogReads == catalogReads + 1)
        #expect(!session.canSend)

        session.choose(Self.channel("design", "Design"))
        #expect(session.notice == nil)
        await session.send()
        #expect(session.phase == .sent)
        #expect(fixture.posts.map(\.channel) == ["studio", "design"])
        #expect(fixture.posts.first?.id != fixture.posts.last?.id)
    }

    @Test func aSuggestionOpensItsChannelOnlyWhileTheServerStillListsIt() async throws {
        let fixture = try ShareHTTPFixture(posts: [])
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try MobileShareHistory(directory: directory, donor: FakeDonor().donor)
        await history.select(serverURL: fixture.serverURL + "/").value

        let elsewhere = try #require(MobileShareTarget(serverURL: "https://elsewhere.example", channelID: "studio"))
        #expect(MobileShareSession(history: history, intent: Self.intent(elsewhere, name: "Studio"),
                                   session: fixture.session).target == nil)

        let studio = try #require(MobileShareTarget(serverURL: fixture.serverURL, channelID: "studio"))
        let renamed = MobileShareSession(history: history, intent: Self.intent(studio, name: "Old Name"),
                                         session: fixture.session)
        #expect(renamed.target == .init(id: "studio", name: "Old Name"))
        await renamed.refreshChannels()
        #expect(renamed.target == .init(id: "studio", name: "Studio"))
        #expect(renamed.agents.map(\.name) == ["Server Lead", "Builder"])

        let gone = try #require(MobileShareTarget(serverURL: fixture.serverURL, channelID: "gone"))
        let stale = MobileShareSession(history: history, intent: Self.intent(gone, name: "Gone"), session: fixture.session)
        #expect(stale.target?.id == "gone")
        await stale.refreshChannels()
        #expect(stale.target == nil)
    }

    @Test func withoutASavedServerThereIsNothingToSendTo() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try MobileShareHistory(directory: directory, donor: FakeDonor().donor)
        let session = MobileShareSession(history: history, intent: nil)
        #expect(session.serverURL == nil)
        #expect(session.catalog == nil)
        session.choose(Self.studio)
        #expect(!session.canSend)
        #expect(MobileShareSession(history: nil, intent: nil).serverURL == nil)
    }

    // MARK: Fixtures

    private static let model = ModelConfiguration(provider: "copilot", name: "model")
    private static let studio = channel("studio", "Studio")

    private static func channel(_ id: String, _ name: String) -> Channel {
        Channel(id: id, name: name, model: model, updatedAt: "2026-10-31T05:00:00Z")
    }

    private static func identifier(_ channel: String) -> String {
        MobileShareTarget(serverURL: "https://toy.example", channelID: channel)!.conversationIdentifier
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tbm-share-\(UUID())")
    }

    private static func history(_ donor: FakeDonor) throws -> (MobileShareHistory, URL) {
        let directory = directory()
        return (try MobileShareHistory(directory: directory, donor: donor.donor), directory)
    }

    /// A session with the saved server, its channels loaded and a web page to share.
    private static func session(_ fixture: ShareHTTPFixture,
                                donor: FakeDonor = FakeDonor()) async throws -> (MobileShareSession, URL) {
        let (history, directory) = try history(donor)
        await history.select(serverURL: fixture.serverURL).value
        let session = MobileShareSession(history: history, intent: nil, session: fixture.session)
        let page = try #require(URL(string: "https://example.com/story"))
        await session.start([NSItemProvider(object: page as NSURL)], title: "Story")
        #expect(session.content?.link?.url == page)
        #expect(session.catalog?.isLoaded == true)
        return (session, directory)
    }

    private static func intent(_ target: MobileShareTarget, name: String) -> INSendMessageIntent {
        INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: nil,
                            speakableGroupName: INSpeakableString(spokenPhrase: name),
                            conversationIdentifier: target.conversationIdentifier, serviceName: nil,
                            sender: nil, attachments: nil)
    }

    nonisolated private static func provider(_ data: Data, type: UTType, name: String? = nil) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: type, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        provider.suggestedName = name
        return provider
    }

    /// A flat color, or opaque noise that PNG can't compress.
    private static func png(width: Int, height: Int, noise: Bool = false) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.47, blue: 0.52, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            var state: UInt32 = 0x9E37_79B9
            for index in 0..<(width * height * 4) where index % 4 != 3 {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                pixels[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
private final class FakeDonor {
    var donated: [INInteraction] = []
    var deleted: [[String]] = []

    var donor: MobileShareHistory.Donor {
        .init(donate: { [self] in donated.append($0) }, delete: { [self] in deleted.append($0) })
    }
}

/// One fake server per test: the catalog lists Studio and Design, and each message post takes the
/// next scripted outcome.
private final class ShareHTTPFixture: Sendable {
    enum Outcome: Sendable {
        case accept
        case status(Int, String)
        case fail(URLError.Code)
    }

    struct Post: Sendable { var channel: String; var id: String; var content: String }
    private struct State { var outcomes: [Outcome]; var posts: [Post] = []; var catalogReads = 0 }
    private final class Storage: Sendable {
        let value: Mutex<State>
        init(_ state: State) { value = Mutex(state) }
    }
    private struct PostBody: Decodable { var id: String; var content: String }
    private struct Accepted: Encodable { var version = 1; var message: ChannelMessage }

    let serverURL: String
    let session: URLSession
    private let host: String
    private let state: Storage
    var posts: [Post] { state.value.withLock { $0.posts } }
    var catalogReads: Int { state.value.withLock { $0.catalogReads } }

    init(posts outcomes: [Outcome]) throws {
        host = "\(UUID().uuidString.lowercased()).share.test"
        serverURL = "http://\(host)"
        let catalog = try JSONEncoder().encode(ChannelCatalog(
            lead: .init(name: "Server Lead", role: "Coordinates", avatar: .init(mark: "M4 12L12 4L20 12", color: "#327785")),
            channels: [.init(id: "studio", name: "Studio", model: .init(provider: "copilot", name: "model"),
                             updatedAt: "2026-10-31T05:00:00Z"),
                       .init(id: "design", name: "Design", model: .init(provider: "copilot", name: "model"),
                             updatedAt: "2026-10-31T05:00:00Z")],
            members: [.init(id: "builder", name: "Builder", channelId: "studio", role: "Builds",
                            avatar: .init(mark: "M4 4L20 20", color: "#ff8800"))]))
        let state = Storage(State(outcomes: outcomes))
        self.state = state
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareHTTPProtocol.self]
        session = URLSession(configuration: configuration)
        ShareHTTPProtocol.handlers.withLock { handlers in
            handlers[host] = { request in
                let url = try #require(request.url)
                if request.httpMethod == "GET", url.path == "/api/v1/channels" {
                    state.value.withLock { $0.catalogReads += 1 }
                    return .success((200, catalog))
                }
                let parts = url.pathComponents
                guard request.httpMethod == "POST", parts.count == 6, parts.last == "messages" else {
                    Issue.record("Unexpected share request: \(request.httpMethod ?? "") \(url.path)")
                    return .success((500, Data()))
                }
                let body = try JSONDecoder().decode(PostBody.self, from: try #require(ShareHTTPProtocol.body(of: request)))
                let outcome = state.value.withLock { state -> Outcome? in
                    state.posts.append(Post(channel: parts[4], id: body.id, content: body.content))
                    return state.outcomes.isEmpty ? nil : state.outcomes.removeFirst()
                }
                switch outcome {
                case .accept:
                    let message = ChannelMessage(id: body.id, sequence: 16, timestamp: "2026-10-31T05:00:00Z",
                                                 sender: .user, content: .text(body.content))
                    return .success((201, try JSONEncoder().encode(Accepted(message: message))))
                case .status(let status, let error):
                    return .success((status, try JSONEncoder().encode(["error": error])))
                case .fail(let code): return .failure(URLError(code))
                case nil:
                    Issue.record("Unscripted post")
                    return .success((500, Data()))
                }
            }
        }
    }

    deinit {
        session.invalidateAndCancel()
        ShareHTTPProtocol.handlers.withLock { $0[host] = nil }
    }
}

private final class ShareHTTPProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> Result<(Int, Data), URLError>
    static let handlers = Mutex<[String: Handler]>([:])

    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try #require(request.url)
            let handler = try #require(Self.handlers.withLock { $0[url.host ?? ""] })
            switch try handler(request) {
            case .success(let (status, data)):
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

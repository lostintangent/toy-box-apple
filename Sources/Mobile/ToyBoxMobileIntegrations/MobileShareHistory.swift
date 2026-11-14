import ChannelClient
import ChannelKit
import Foundation
import ImageIO
import Intents
import OSLog
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

/// The app's servers and recently used channels the share extension reads from the app group, and
/// the share sheet suggestions that mirror those recents. Every change rereads the file first, since
/// the app and the extension both write it.
@MainActor
public final class MobileShareHistory {
    public static let fileName = "share-history.json"
    static let recentLimit = 20

    public struct Donor {
        public var donate: @MainActor (INInteraction) async throws -> Void
        public var delete: @MainActor ([String]) async throws -> Void

        public init(donate: @escaping @MainActor (INInteraction) async throws -> Void,
                    delete: @escaping @MainActor ([String]) async throws -> Void) {
            self.donate = donate
            self.delete = delete
        }

        public static var system: Donor {
            Donor(donate: { try await $0.donate() }, delete: { try await INInteraction.delete(with: $0) })
        }
    }

    /// A server the app has, with the name it last answered, or its host before it answers.
    public struct Server: Codable, Equatable, Sendable {
        public var url: String
        public var name: String

        public init(url: String, name: String? = nil) {
            self.url = url
            self.name = name ?? ChannelCatalogStore.name(of: url)
        }
    }

    private struct Saved: Codable, Equatable {
        var servers: [Server]
        var recents: [ChannelTarget]

        init(servers: [Server], recents: [ChannelTarget]) {
            self.servers = servers
            self.recents = recents
        }

        private enum CodingKeys: String, CodingKey { case servers, recents }
        /// The history from before the phone had several servers: one server and its recent channels.
        private enum SingleServerKeys: String, CodingKey { case serverURL, recentChannelIDs }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.servers) {
                servers = try container.decode([Server].self, forKey: .servers)
                recents = try container.decode([ChannelTarget].self, forKey: .recents)
                return
            }
            let single = try decoder.container(keyedBy: SingleServerKeys.self)
            let server = try single.decode(String.self, forKey: .serverURL)
            servers = [.init(url: server)]
            recents = try single.decode([String].self, forKey: .recentChannelIDs).compactMap {
                ChannelTarget(serverURL: server, channelID: $0)
            }
        }
    }

    private let file: URL
    private let donor: Donor
    private var donations: Task<Void, Never>?
    private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Share")

    public init(directory: URL? = nil, donor: Donor = .system) throws {
        file = try (directory ?? MobileSharedContainer.url()).appendingPathComponent(Self.fileName)
        self.donor = donor
    }

    /// The app's servers in its order, exactly as it handed them over.
    public var servers: [Server] { load()?.servers ?? [] }
    /// The most recent first, across every server.
    public var recents: [ChannelTarget] { load()?.recents ?? [] }

    /// Saves the app's servers. One the app no longer has loses its recents and their suggestions.
    @discardableResult
    public func select(servers: [Server]) -> Task<Void, Never> {
        let current = load()
        guard current?.servers != servers, current != nil || !servers.isEmpty else { return enqueue {} }
        let addresses = Set(servers.compactMap { ChannelWaitingRequest.normalizedServer($0.url) })
        let recents = current?.recents ?? []
        let removed = recents.filter { !addresses.contains($0.serverURL) }.map(\.identifier)
        write(Saved(servers: servers, recents: recents.filter { addresses.contains($0.serverURL) }))
        return enqueue { [donor] in if !removed.isEmpty { try await donor.delete(removed) } }
    }

    /// Moves a channel to the front of the recents and suggests it again, with its avatar. A send on a
    /// server the app doesn't have changes nothing.
    @discardableResult
    public func recordSend(serverURL: String, channelID: String, name: String,
                           avatar: ChannelAvatar? = nil) -> Task<Void, Never> {
        guard var next = load(), let target = ChannelTarget(serverURL: serverURL, channelID: channelID),
              next.servers.contains(where: { ChannelWaitingRequest.normalizedServer($0.url) == target.serverURL })
        else { return enqueue {} }
        next.recents.removeAll { $0 == target }
        next.recents.insert(target, at: 0)
        let evicted = next.recents.dropFirst(Self.recentLimit).map(\.identifier)
        next.recents = Array(next.recents.prefix(Self.recentLimit))
        write(next)
        return enqueue { [donor] in
            if !evicted.isEmpty { try await donor.delete(evicted) }
            let mark = await Self.markImage(avatar, serverURL: serverURL)
            try await donor.donate(Self.interaction(target, name: name, mark: mark))
        }
    }

    /// Forgets channels the server no longer lists, along with their suggestions.
    @discardableResult
    public func prune(serverURL: String, keeping channelIDs: Set<String>) -> Task<Void, Never> {
        guard var next = load(), let server = ChannelWaitingRequest.normalizedServer(serverURL) else { return enqueue {} }
        let removed = next.recents.filter { $0.serverURL == server && !channelIDs.contains($0.channelID) }
        guard !removed.isEmpty else { return enqueue {} }
        next.recents.removeAll { removed.contains($0) }
        write(next)
        let identifiers = removed.map(\.identifier)
        return enqueue { [donor] in try await donor.delete(identifiers) }
    }

    static func interaction(_ target: ChannelTarget, name: String, mark: Data?) -> INInteraction {
        let intent = INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText, content: nil,
            speakableGroupName: INSpeakableString(spokenPhrase: name),
            conversationIdentifier: target.identifier, serviceName: nil, sender: nil, attachments: nil)
        if let mark { intent.setImage(INImage(imageData: mark), forParameterNamed: \.speakableGroupName) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = target.identifier
        return interaction
    }

    /// The channel's avatar at 3x, drawn into its own bitmap rather than `ImageRenderer.uiImage`. An
    /// image loads first, since a renderer draws only what's already there.
    static func markImage(_ avatar: ChannelAvatar?, serverURL: String) async -> Data? {
        let api = try? ChannelAPI(serverURL: serverURL)
        if case .image(let address)? = avatar, let api { await ChannelAvatarImages.shared.load(address, api: api) }
        let renderer = ImageRenderer(content: ChannelMark(avatar, api: api, size: 60))
        var png: Data?
        renderer.render { size, draw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                data: nil, width: Int((size.width * 3).rounded(.up)), height: Int((size.height * 3).rounded(.up)),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.scaleBy(x: 3, y: 3)
            draw(context)
            let data = NSMutableData()
            guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { png = data as Data }
        }
        return png
    }

    private func load() -> Saved? {
        do { return try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch {
            logger.error("Could not read the share history: \(error.localizedDescription)")
            return nil
        }
    }

    private func write(_ next: Saved) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
        } catch { logger.error("Could not save the share history: \(error.localizedDescription)") }
    }

    /// Suggestion changes run one at a time in the order they were asked for.
    private func enqueue(_ work: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let previous = donations
        let task = Task { [logger] in
            await previous?.value
            do { try await work() }
            catch { logger.error("Could not update share suggestions: \(error.localizedDescription)") }
        }
        donations = task
        return task
    }
}

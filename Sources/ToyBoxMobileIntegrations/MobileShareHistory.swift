import ChannelKit
import Foundation
import ImageIO
import Intents
import OSLog
import SwiftUI
import ToyBoxUI
import UniformTypeIdentifiers

/// One channel on one server, as a share sheet suggestion names it.
public struct MobileShareTarget: Equatable, Hashable, Sendable {
    public let serverURL: String
    public let channelID: String

    public init?(serverURL: String, channelID: String) {
        guard !channelID.isEmpty, let server = ChannelWaitingRequest.normalizedServer(serverURL) else { return nil }
        self.serverURL = server
        self.channelID = channelID
    }

    public init?(conversationIdentifier: String) {
        let items = URLComponents(string: conversationIdentifier)?.queryItems ?? []
        guard let server = items.first(where: { $0.name == "server" })?.value,
              let channel = items.first(where: { $0.name == "channel" })?.value else { return nil }
        self.init(serverURL: server, channelID: channel)
    }

    /// Also each donation's group identifier, so one channel's suggestion can be removed alone.
    public var conversationIdentifier: String {
        var components = URLComponents()
        components.queryItems = [.init(name: "server", value: serverURL), .init(name: "channel", value: channelID)]
        return components.string ?? ""
    }
}

/// The saved server and recently used channels the share extension reads from the app group, and the
/// share sheet suggestions that mirror those recents. Every change rereads the file first, since
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

    private struct Saved: Codable, Equatable {
        var serverURL: String
        var recentChannelIDs: [String]
    }

    private let file: URL
    private let donor: Donor
    private var donations: Task<Void, Never>?
    private let logger = Logger(subsystem: "dev.toybox.mobile", category: "Share")

    public init(directory: URL? = nil, donor: Donor = .system) throws {
        file = try (directory ?? MobileSharedContainer.url()).appendingPathComponent(Self.fileName)
        self.donor = donor
    }

    /// The server the app last connected to, exactly as it saved it.
    public var serverURL: String? { load()?.serverURL }
    public var recentChannelIDs: [String] { load()?.recentChannelIDs ?? [] }

    /// A different server starts an empty history and removes the old server's suggestions.
    @discardableResult
    public func select(serverURL: String) -> Task<Void, Never> {
        let current = load()
        guard current?.serverURL != serverURL else { return enqueue {} }
        let sameServer = current.flatMap { ChannelWaitingRequest.normalizedServer($0.serverURL) }
            == ChannelWaitingRequest.normalizedServer(serverURL)
        let removed = sameServer ? [] : targets(current, current?.recentChannelIDs ?? [])
        write(Saved(serverURL: serverURL, recentChannelIDs: sameServer ? current?.recentChannelIDs ?? [] : []))
        return enqueue { [donor] in if !removed.isEmpty { try await donor.delete(removed) } }
    }

    /// Moves a channel to the front of the recents and suggests it again. A send on another server
    /// than the saved one changes nothing.
    @discardableResult
    public func recordSend(serverURL: String, channelID: String, name: String) -> Task<Void, Never> {
        guard var next = load(), let target = MobileShareTarget(serverURL: serverURL, channelID: channelID),
              ChannelWaitingRequest.normalizedServer(next.serverURL) == target.serverURL else { return enqueue {} }
        next.recentChannelIDs.removeAll { $0 == channelID }
        next.recentChannelIDs.insert(channelID, at: 0)
        let evicted = targets(next, Array(next.recentChannelIDs.dropFirst(Self.recentLimit)))
        next.recentChannelIDs = Array(next.recentChannelIDs.prefix(Self.recentLimit))
        write(next)
        return enqueue { [donor] in
            if !evicted.isEmpty { try await donor.delete(evicted) }
            try await donor.donate(Self.interaction(target, name: name))
        }
    }

    /// Forgets channels the server no longer lists, along with their suggestions.
    @discardableResult
    public func prune(serverURL: String, keeping channelIDs: Set<String>) -> Task<Void, Never> {
        guard var next = load(),
              ChannelWaitingRequest.normalizedServer(next.serverURL) == ChannelWaitingRequest.normalizedServer(serverURL)
        else { return enqueue {} }
        let removed = next.recentChannelIDs.filter { !channelIDs.contains($0) }
        guard !removed.isEmpty else { return enqueue {} }
        next.recentChannelIDs.removeAll { !channelIDs.contains($0) }
        write(next)
        let targets = targets(next, removed)
        return enqueue { [donor] in try await donor.delete(targets) }
    }

    static func interaction(_ target: MobileShareTarget, name: String) -> INInteraction {
        let intent = INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText, content: nil,
            speakableGroupName: INSpeakableString(spokenPhrase: name),
            conversationIdentifier: target.conversationIdentifier, serviceName: nil, sender: nil, attachments: nil)
        if let mark = markImage { intent.setImage(INImage(imageData: mark), forParameterNamed: \.speakableGroupName) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = target.conversationIdentifier
        return interaction
    }

    /// The channel mark at 3x, drawn into its own bitmap rather than `ImageRenderer.uiImage`.
    private static let markImage: Data? = {
        let renderer = ImageRenderer(content: ChannelMark(size: 60))
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
    }()

    private func targets(_ saved: Saved?, _ channelIDs: [String]) -> [String] {
        guard let saved else { return [] }
        return channelIDs.compactMap {
            MobileShareTarget(serverURL: saved.serverURL, channelID: $0)?.conversationIdentifier
        }
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

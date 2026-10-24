import AppKit
import ChannelKit
import OSLog
import SwiftUI
import WidgetKit

@MainActor
final class WidgetSnapshotPublisher {
    let isEnabled: Bool
    private var previous: NeedsYouSnapshot?
    private var loadedPrevious = false
    private var avatars: [String: (ChannelAgent, Data)] = [:]
    private let logger = Logger(subsystem: "dev.toybox.desktop", category: "Widget")

    init(enabled: Bool) {
        isEnabled = enabled && Bundle.main.object(forInfoDictionaryKey: NeedsYouSnapshot.groupInfoKey) as? String
            == NeedsYouSnapshot.appGroup
    }

    func update(status: MenuBarStatus, serverURL: String, hasCatalog: Bool, now: Date = .now) {
        guard isEnabled else { return }
        do {
            guard let directory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: NeedsYouSnapshot.appGroup
            ) else { throw WidgetSnapshotError.unavailableGroup }
            let file = directory.appendingPathComponent(NeedsYouSnapshot.fileName)
            if !loadedPrevious {
                loadedPrevious = true
                do {
                    let cached = try JSONDecoder().decode(NeedsYouSnapshot.self, from: Data(contentsOf: file))
                    if cached.version == 1 { previous = cached }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    // The first launch has no snapshot yet.
                } catch {
                    logger.error("Could not restore the widget snapshot: \(error.localizedDescription, privacy: .public)")
                }
            }
            var snapshot = Self.snapshot(status: status, serverURL: serverURL, hasCatalog: hasCatalog,
                                         now: now, avatar: avatar)
            if !hasCatalog, let previous, previous.serverURL == serverURL {
                snapshot = previous
                snapshot.isOffline = true
            }
            if let previous {
                snapshot.updatedAt = previous.updatedAt
                if snapshot == previous, now.timeIntervalSince(previous.updatedAt) < 15 * 60 { return }
                snapshot.updatedAt = now
            }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: file, options: .atomic)
            previous = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: NeedsYouSnapshot.kind)
        } catch {
            logger.error("Could not publish the widget snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func snapshot(status: MenuBarStatus, serverURL: String, hasCatalog: Bool, now: Date,
                         avatar: (ChannelAgent?) -> Data?) -> NeedsYouSnapshot {
        NeedsYouSnapshot(
            serverURL: serverURL, updatedAt: now, isOffline: status.unreachableHost != nil,
            isAvailable: hasCatalog, waitingCount: status.waiting.count,
            requests: status.waiting.prefix(5).compactMap { item in
                guard let sequence = item.sequence, sequence > 0 else { return nil }
                return .init(channelID: item.id, channelName: item.name, sequence: sequence,
                             quote: item.quote ?? MenuBarStatus.needsReply, agentName: item.agent?.name,
                             requestedAt: item.requestedAt, avatarPNG: avatar(item.agent))
            }
        )
    }

    private func avatar(_ agent: ChannelAgent?) -> Data? {
        guard let agent else { return nil }
        if let cached = avatars[agent.id], cached.0 == agent { return cached.1 }
        let renderer = ImageRenderer(content: AgentAvatarView(agent: agent, size: 24))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            logger.error("Could not render a widget avatar.")
            return nil
        }
        avatars[agent.id] = (agent, data)
        return data
    }
}

enum WidgetSnapshotError: LocalizedError {
    case unavailableGroup, differentServer

    var errorDescription: String? {
        switch self {
        case .unavailableGroup: "Toy Box cannot access its widget's shared container."
        case .differentServer: "This request belongs to another server. Switch servers in Settings to open it."
        }
    }
}

enum WidgetActionLink: Equatable {
    case main, quickSend, inbox
    case open(NeedsYouRequestLink), reply(NeedsYouRequestLink)

    init?(url: URL) {
        if url == URL(string: "toybox-desktop://quick-send") {
            self = .quickSend
        } else if url == URL(string: "toybox-desktop://inbox") {
            self = .inbox
        } else if url == NeedsYouSnapshot.mainURL {
            self = .main
        } else if let request = NeedsYouRequestLink(url: url) {
            self = .open(request)
        } else if let request = NeedsYouRequestLink(replyURL: url) {
            self = .reply(request)
        } else {
            return nil
        }
    }
}

extension AppModel {
    func openWidgetURL(_ url: URL) throws -> Bool {
        guard let action = WidgetActionLink(url: url) else { return false }
        switch action {
        case .main:
            activate(channelID: nil)
        case .quickSend:
            guard quickSend.isEnabled else { throw QuickSendIntake.IntakeError.unavailable }
            quickSend.present()
        case .inbox:
            guard quickSend.isEnabled else { throw QuickSendIntake.IntakeError.unavailable }
            quickSend.dismiss()
            menuBar.requestPresentation()
        case .open(let request):
            guard request.serverURL == serverURL else { throw WidgetSnapshotError.differentServer }
            activate(channelID: request.channelID, sequence: request.sequence)
        case .reply(let request):
            guard request.serverURL == serverURL else { throw WidgetSnapshotError.differentServer }
            guard quickSend.isEnabled else { throw QuickSendIntake.IntakeError.unavailable }
            quickSend.present(replyTo: request)
        }
        return true
    }
}

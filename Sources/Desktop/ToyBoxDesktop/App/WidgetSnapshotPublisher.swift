import ChannelClient
import ChannelKit
import Foundation
import OSLog
import WidgetKit

@MainActor
final class WidgetSnapshotPublisher {
    let isEnabled: Bool
    private var previous: NeedsYouSnapshot?
    private var loadedPrevious = false
    private let directory: URL?
    private let reload: @MainActor () -> Void
    private let logger = Logger(subsystem: "dev.toybox.desktop", category: "Widget")

    init(enabled: Bool, directory: URL? = nil,
         reload: @escaping @MainActor () -> Void = {
             WidgetCenter.shared.reloadTimelines(ofKind: NeedsYouSnapshot.kind)
             ControlCenter.shared.reloadControls(ofKind: NeedsYouSnapshot.controlKind)
         }) {
        isEnabled = enabled && (directory != nil
            || Bundle.main.object(forInfoDictionaryKey: NeedsYouSnapshot.groupInfoKey) as? String
                == NeedsYouSnapshot.appGroup)
        self.directory = directory
        self.reload = reload
    }

    /// One server as the app sees it.
    struct Source {
        /// Exactly as the app saved it.
        var serverURL: String
        var isOffline: Bool
        /// Its waiting requests, or nil until its catalog loads.
        var waiting: [ChannelCatalogStore.WaitingRequest]?
    }

    func update(_ sources: [Source], now: Date = .now) {
        guard isEnabled else { return }
        do {
            guard let directory = directory ?? FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: NeedsYouSnapshot.appGroup
            ) else { throw WidgetSnapshotError.unavailableGroup }
            let file = directory.appending(path: NeedsYouSnapshot.fileName)
            if !loadedPrevious {
                loadedPrevious = true
                do {
                    let data = try Data(contentsOf: file)
                    if try NeedsYouSnapshot.version(of: data) == NeedsYouSnapshot.currentVersion {
                        previous = try JSONDecoder().decode(NeedsYouSnapshot.self, from: data)
                    }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    // The first launch has no snapshot yet.
                } catch {
                    logger.error("Could not restore the widget snapshot: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let snapshot = Self.snapshot(sources, previous: previous, now: now)
                .replacing(previous, at: now) else { return }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: file, options: .atomic)
            previous = snapshot
            reload()
        } catch {
            logger.error("Could not publish the widget snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One part per server, in Settings order. A server whose catalog hasn't loaded keeps its last
    /// part, out of date, and claims no empty inbox when it has none.
    static func snapshot(_ sources: [Source], previous: NeedsYouSnapshot?, now: Date) -> NeedsYouSnapshot {
        NeedsYouSnapshot(servers: sources.map { source in
            if let waiting = source.waiting {
                return .init(serverURL: source.serverURL, updatedAt: now, isOffline: source.isOffline,
                             isAvailable: true, waiting: waiting)
            }
            guard source.isOffline || previous?.servers.contains(where: { $0.serverURL == source.serverURL }) == true else {
                return .init(serverURL: source.serverURL, updatedAt: now, isOffline: false, isAvailable: false,
                             waiting: [])
            }
            return .offline(source.serverURL, in: previous, at: now)
        })
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
            activate(nil)
        case .quickSend:
            guard quickSend.isEnabled else { throw QuickSendIntake.IntakeError.unavailable }
            quickSend.present()
        case .inbox:
            guard quickSend.isEnabled else { throw QuickSendIntake.IntakeError.unavailable }
            quickSend.dismiss()
            menuBar.requestPresentation()
        case .open(let request):
            activate(ChannelTarget(serverURL: request.serverURL, channelID: request.channelID),
                     sequence: request.sequence)
        case .reply(let request):
            guard request.serverURL == serverURL else { throw WidgetSnapshotError.differentServer }
            guard quickSend.isEnabled else { throw QuickSendIntake.IntakeError.unavailable }
            quickSend.present(replyTo: request)
        }
        return true
    }
}

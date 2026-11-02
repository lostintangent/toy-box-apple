import Foundation
import Observation
import Sparkle

@MainActor @Observable
final class AppUpdates {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    private(set) var canCheckForUpdates = false
    private(set) var allowsAutomaticUpdates = false
    private var checksAutomatically = false
    private var downloadsAutomatically = false

    var isRunning: Bool { controller != nil }

    var automaticallyChecksForUpdates: Bool {
        get { checksAutomatically }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { downloadsAutomatically }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    init(isSnapshot: Bool, bundle: Bundle = .main) {
        guard Self.shouldStart(hasFeedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil,
                               isSnapshot: isSnapshot) else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                     userDriverDelegate: nil)
        self.controller = controller
        let properties: [KeyPath<SPUUpdater, Bool>] = [
            \.canCheckForUpdates, \.allowsAutomaticUpdates,
            \.automaticallyChecksForUpdates, \.automaticallyDownloadsUpdates,
        ]
        observations = properties.map { property in
            controller.updater.observe(property, options: [.initial, .new]) { [weak self] _, _ in
                // Sparkle's updater and its KVO notifications are main-thread-only.
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    static func shouldStart(hasFeedURL: Bool, isSnapshot: Bool) -> Bool {
        hasFeedURL && !isSnapshot
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private func refresh() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        checksAutomatically = updater.automaticallyChecksForUpdates
        downloadsAutomatically = updater.automaticallyDownloadsUpdates
    }
}

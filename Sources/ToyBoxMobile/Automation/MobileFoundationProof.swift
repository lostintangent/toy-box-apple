import SwiftUI

#if DEBUG && targetEnvironment(simulator)
extension View {
    func mobileFoundationProofIfRequested() -> some View { modifier(MobileFoundationProof()) }
}

private struct MobileFoundationProof: ViewModifier {
    @ViewState private var showsChannels = false

    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.arguments.contains("--activity-fixture-proof") {
            ActivityFixtureProofView()
        } else if (ProcessInfo.processInfo.arguments.contains("--foundation-proof")
                   || ProcessInfo.processInfo.arguments.contains("--notification-proof")), !showsChannels {
            FoundationProofView(showChannels: { showsChannels = true })
        } else {
            content
        }
    }
}

import ActivityKit
import ChannelKit
import ToyBoxMobileIntegrations
import UserNotifications
import WidgetKit

@MainActor
private struct FoundationProofView: View {
    let showChannels: () -> Void
    @Environment(AppModel.self) private var model
    @ViewState private var marker = ""
    @ViewState private var result = "Not prepared"
    @ViewState private var activityID: String?
    @ViewState private var isSchedulingNotification = false
    @ViewState private var preparedNotification: ChannelNotifications.PreparedProofNotification?
    @ViewState private var didRunNotificationProof = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Simulator foundation only") {
                    Text(result).accessibilityIdentifier("foundation-result")
                    Text("Shared marker: \(marker)")
                    Button("Show Channels", action: showChannels)
                    Button("Prepare Shared Container") { prepare() }
                    Button("Allow Proof Notifications") {
                        Task {
                            do {
                                let allowed = try await UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound, .badge])
                                result = allowed ? "Notifications allowed" : "Notifications denied"
                            } catch { result = error.localizedDescription }
                        }
                    }
                    Group {
                        Button("Deliver Enriched Request") { scheduleNotification(.request) }
                        Button("Deliver Enriched Completion") { scheduleNotification(.completion) }
                        Button("Prepare Offline Request") { prepareOfflineNotification() }
                    }
                    .disabled(isSchedulingNotification)
                    Button("Deliver Prepared Offline Request") {
                        guard let preparedNotification else {
                            result = "Prepare a request online first."
                            return
                        }
                        scheduleNotification(.request, prepared: preparedNotification)
                    }
                    .disabled(isSchedulingNotification || preparedNotification == nil)
                    Button("Start Local Activity") {
                        do {
                            let activity = try Activity.request(
                                attributes: FoundationActivity(marker: marker),
                                content: .init(state: .init(update: 1), staleDate: .now.addingTimeInterval(300)),
                                pushType: nil)
                            activityID = activity.id
                            result = "Activity started: update 1"
                        } catch { result = error.localizedDescription }
                    }
                    Button("Update Local Activity") {
                        Task {
                            guard let activityID else { result = "Start an activity first"; return }
                            let updated = await FoundationActivities.update(id: activityID)
                            result = updated ? "Activity updated: update 2" : "Activity no longer exists"
                        }
                    }
                    Button("End Local Activities") {
                        Task {
                            await FoundationActivities.endAll()
                            activityID = nil
                            result = "Activities ended"
                        }
                    }
                    Button("Read Shared Receipts") { readReceipts() }
                }
            }
            .navigationTitle("Foundation Proof")
            .task {
                await runNotificationProofIfRequested()
                let category = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
                let sizes = [UIFont.TextStyle.body, .headline, .footnote, .caption1].map {
                    "\($0.rawValue)=\(UIFont.preferredFont(forTextStyle: $0, compatibleWith: category).pointSize)"
                }
                do {
                    let container = try MobileSharedContainer.url()
                    try Data(sizes.joined(separator: "\n").utf8)
                        .write(to: container.appending(path: "foundation-type-sizes.txt"), options: .atomic)
                } catch { result = "Type probe failed: \(error.localizedDescription)" }
            }
        }
    }

    private struct NotificationProofReceipt: Codable {
        var action: String
        var state: String
        var elapsedSeconds: Double
        var message: String
        var delivery: ChannelNotifications.ProofDelivery?

        func write(to file: URL) throws {
            try JSONEncoder().encode(self).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func runNotificationProofIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !didRunNotificationProof, let index = arguments.firstIndex(of: "--notification-proof") else { return }
        didRunNotificationProof = true
        do {
            guard arguments.indices.contains(index + 1),
                  let action = ChannelNotifications.ProofAction(rawValue: arguments[index + 1]) else {
                throw ProofFailure.invalidNotificationAction
            }
            await model.notifications.start()
            let directory = try MobileSharedContainer.url()
            let file = directory.appendingPathComponent("notification-proof-result.json")
            var receipt = NotificationProofReceipt(
                action: action.rawValue, state: "running", elapsedSeconds: 0, message: "Preparing notification proof")
            try receipt.write(to: file)
            result = receipt.message
            let started = ContinuousClock.now
            do {
                receipt.delivery = try await model.notifications.runProofNotificationAction(action, directory: directory)
                receipt.state = "completed"
                receipt.message = action == .prepareOffline
                    ? "Routing prepared online. Stop the demo before the deliver-offline launch."
                    : "Notification scheduled for thirty seconds from now."
            } catch {
                receipt.state = "failed"
                receipt.message = "Notification proof failed: \(error.localizedDescription)"
            }
            let elapsed = started.duration(to: .now).components
            receipt.elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            result = receipt.message
            try receipt.write(to: file)
        } catch {
            result = "Notification proof failed: \(error.localizedDescription)"
        }
    }

    private func prepareOfflineNotification() {
        isSchedulingNotification = true
        preparedNotification = nil
        result = "Preparing request routing online"
        Task {
            defer { isSchedulingNotification = false }
            do {
                preparedNotification = try await model.notifications.prepareProofNotification(.request)
                result = "Request prepared. Stop the demo server, then deliver the prepared offline request."
            } catch {
                result = "Preparation failed: \(error.localizedDescription)"
            }
        }
    }

    private func scheduleNotification(_ kind: ChannelPushPayload.Kind,
                                      prepared: ChannelNotifications.PreparedProofNotification? = nil) {
        isSchedulingNotification = true
        result = prepared == nil ? "Preparing \(kind.rawValue) alert" : "Enriching the prepared request while offline"
        Task {
            defer { isSchedulingNotification = false }
            do {
                if let prepared {
                    try await model.notifications.schedulePreparedProofNotification(prepared)
                    preparedNotification = nil
                } else {
                    try await model.notifications.scheduleProofNotification(kind)
                }
                result = "\(prepared == nil ? "Enriched" : "Prepared") \(kind.rawValue) scheduled. Return Home or lock the simulator within 30 seconds."
            } catch {
                result = "Notification failed: \(error.localizedDescription)"
            }
        }
    }

    private func prepare() {
        do {
            let container = try MobileSharedContainer.url()
            marker = UUID().uuidString
            try Data(marker.utf8).write(to: container.appending(path: "foundation-marker.txt"), options: .atomic)
            guard let symbol = UIImage(systemName: "person.fill") else { throw ProofFailure.avatarUnavailable }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128))
            let image = renderer.image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 24, y: 24, width: 80, height: 80))
            }
            guard let png = image.pngData() else { throw ProofFailure.pngEncodingFailed }
            try png.write(to: container.appending(path: "foundation-avatar.png"), options: .atomic)
            _ = try MobileFoundationProbe.record("app")
            WidgetCenter.shared.reloadAllTimelines()
            result = "Shared container prepared"
        } catch { result = "Prepare failed: \(error.localizedDescription)" }
    }

    private enum ProofFailure: LocalizedError {
        case avatarUnavailable
        case pngEncodingFailed
        case invalidNotificationAction

        var errorDescription: String? {
            switch self {
            case .avatarUnavailable: "The proof avatar symbol is unavailable."
            case .pngEncodingFailed: "The proof avatar could not be encoded as PNG."
            case .invalidNotificationAction: "Use request, prepare-offline or deliver-offline for notification proof."
            }
        }
    }

    private func readReceipts() {
        do {
            let container = try MobileSharedContainer.url()
            let values = try ["app", "widget", "notification"].map { component in
                let receipt = try String(contentsOf: container.appending(path: "foundation-\(component).txt"),
                                         encoding: .utf8)
                return "\(component): \(receipt == marker ? "matched" : "MISMATCH")"
            }
            result = values.joined(separator: "\n")
        } catch { result = "Receipt read failed: \(error.localizedDescription)" }
    }
}

private enum FoundationActivities {
    @concurrent static func update(id: String) async -> Bool {
        guard let activity = Activity<FoundationActivity>.activities.first(where: { $0.id == id }) else { return false }
        await activity.update(.init(state: .init(update: 2), staleDate: .now.addingTimeInterval(300)))
        return true
    }

    @concurrent static func endAll() async {
        for activity in Activity<FoundationActivity>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif

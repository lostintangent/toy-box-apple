import SwiftUI

#if DEBUG && targetEnvironment(simulator)
extension View {
    func mobileFoundationProofIfRequested() -> some View { modifier(MobileFoundationProof()) }
}

private struct MobileFoundationProof: ViewModifier {
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.arguments.contains("--foundation-proof") {
            FoundationProofView()
        } else {
            content
        }
    }
}

import ActivityKit
import ToyBoxMobileIntegrations
import UserNotifications
import WidgetKit

@MainActor
private struct FoundationProofView: View {
    @ViewState private var marker = ""
    @ViewState private var result = "Not prepared"
    @ViewState private var activityID: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Simulator foundation only") {
                    Text(result).accessibilityIdentifier("foundation-result")
                    Text("Shared marker: \(marker)")
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

        var errorDescription: String? {
            switch self {
            case .avatarUnavailable: "The proof avatar symbol is unavailable."
            case .pngEncodingFailed: "The proof avatar could not be encoded as PNG."
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

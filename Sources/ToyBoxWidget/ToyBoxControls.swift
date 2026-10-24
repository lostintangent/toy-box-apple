import AppIntents
import ChannelKit
import SwiftUI
import ToyBoxControlIntents
import WidgetKit

struct QuickSendControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: NeedsYouSnapshot.quickSendControlKind) {
            ControlWidgetButton(action: OpenToyBoxControlIntent(target: .quickSend)) {
                Label("Quick Send", systemImage: "square.and.pencil")
                    .controlWidgetActionHint("Open Quick Send")
            }
        }
        .displayName("Quick Send")
        .description("Open Quick Send to write a message to your team.")
    }
}

struct NeedsYouControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: NeedsYouSnapshot.controlKind, provider: NeedsYouControlProvider()) { value in
            ControlWidgetButton(action: OpenToyBoxControlIntent(target: .needsYou)) {
                Label("Needs You", systemImage: "questionmark.bubble")
                    .controlWidgetStatus(Text(value.status))
                    .controlWidgetActionHint("Open inbox")
                    .accessibilityLabel("Needs You, \(value.status)")
            }
        }
        .displayName("Needs You")
        .description("See how many teams are waiting for you and open your inbox.")
    }
}

struct NeedsYouControlProvider: ControlValueProvider {
    var read: @Sendable () -> NeedsYouSnapshot? = { WidgetSnapshotReader.load() }
    var now: @Sendable () -> Date = { .now }

    var previewValue: NeedsYouControlValue { .init(waitingCount: 2, isStale: false) }

    func currentValue() async throws -> NeedsYouControlValue {
        .init(snapshot: read(), now: now())
    }
}

struct NeedsYouControlValue: Equatable, Sendable {
    var waitingCount: Int?
    var isStale: Bool

    init(waitingCount: Int?, isStale: Bool) {
        self.waitingCount = waitingCount
        self.isStale = isStale
    }

    init(snapshot: NeedsYouSnapshot?, now: Date) {
        guard let snapshot, snapshot.version == 1, snapshot.isAvailable, snapshot.waitingCount >= 0 else {
            self.init(waitingCount: nil, isStale: false)
            return
        }
        self.init(waitingCount: snapshot.waitingCount, isStale: snapshot.isStale(at: now))
    }

    var status: String {
        guard let waitingCount else { return "Open Toy Box to connect" }
        if isStale {
            return waitingCount > 0 ? "\(waitingCount) waiting · May be out of date" : "May be out of date"
        }
        return waitingCount == 0 ? "Nothing needs you" : "\(waitingCount) waiting"
    }
}

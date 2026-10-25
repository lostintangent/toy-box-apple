import ChannelKit
import Foundation
import Observation

@MainActor @Observable
final class TranscriptDocumentState {
    struct Snapshot: Equatable {
        var hasLanded = false
        var isAtBottom = true
        var visibleSequence: Int?
    }

    struct Failure: Equatable {
        let target: String
        let token = UUID()
    }

    struct Command: Equatable {
        let event: TranscriptScrollModel.Event
        let token = UUID()
    }

    private(set) var snapshot = Snapshot()
    private(set) var failure: Failure?
    private(set) var command: Command?
    @ObservationIgnored weak var coordinator: TranscriptTablePrototype.Coordinator?

    func send(_ event: TranscriptScrollModel.Event) {
        // Expansion captures its old offset before SwiftUI changes the row.
        if case .toggledExpansion = event, coordinator?.captureExpansion(event) == true {
            command = Command(event: .layoutChanged)
        } else {
            command = Command(event: event)
        }
    }

    func attach(_ coordinator: TranscriptTablePrototype.Coordinator) {
        self.coordinator = coordinator
    }

    func publish(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    func reportUnavailable(_ target: String) {
        failure = Failure(target: target)
    }
}

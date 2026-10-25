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

    private(set) var hasLanded = false
    private(set) var isAtBottom = true
    private(set) var visibleSequence: Int?
    var snapshot: Snapshot {
        Snapshot(hasLanded: hasLanded, isAtBottom: isAtBottom, visibleSequence: visibleSequence)
    }
    private(set) var failure: Failure?
    private(set) var command: Command?
    @ObservationIgnored weak var coordinator: TranscriptTablePrototype.Coordinator?
    @ObservationIgnored private var publication: Task<Void, Never>?
    @ObservationIgnored private var pendingSnapshot: Snapshot?

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

    @discardableResult
    func publish(_ snapshot: Snapshot) -> Task<Void, Never>? {
        guard pendingSnapshot != snapshot else { return publication }
        cancelPublication()
        guard self.snapshot != snapshot else { return nil }
        pendingSnapshot = snapshot
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            if self.hasLanded != snapshot.hasLanded { self.hasLanded = snapshot.hasLanded }
            if self.isAtBottom != snapshot.isAtBottom { self.isAtBottom = snapshot.isAtBottom }
            if self.visibleSequence != snapshot.visibleSequence { self.visibleSequence = snapshot.visibleSequence }
            self.pendingSnapshot = nil
            self.publication = nil
        }
        publication = task
        return task
    }

    func cancelPublication() {
        publication?.cancel()
        publication = nil
        pendingSnapshot = nil
    }

    func reportUnavailable(_ target: String) {
        failure = Failure(target: target)
    }
}

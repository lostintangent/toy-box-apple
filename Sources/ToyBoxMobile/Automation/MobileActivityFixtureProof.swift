#if DEBUG && targetEnvironment(simulator)
import ActivityKit
import ChannelKit
import Foundation
import OSLog
import SwiftUI
import UIKit

@MainActor
enum MobileActivityFixtureProof {
    enum Failure: LocalizedError {
        case missingFixture, invalidEnvelope, needsUpdate, unavailableActivity, notDemoServer, missingDemoChannel
        case needsForeground, needsBackground, backgroundTimeUnavailable

        var errorDescription: String? {
            switch self {
            case .missingFixture: "The debug bundle is missing its Activity fixture."
            case .invalidEnvelope: "The Activity fixture's event or freshness does not match its state."
            case .needsUpdate: "Start the local proof with an active Activity fixture."
            case .unavailableActivity: "Start a local fixture Activity for the current registration first."
            case .notDemoServer: "Connect to the local demo server on port 3210 first."
            case .missingDemoChannel: "The demo server has no studio-demo channel."
            case .needsForeground: "Autoplay needs the foreground to start its local Activity."
            case .needsBackground: "Return Home or lock the simulator to begin autoplay."
            case .backgroundTimeUnavailable: "Could not reserve background time for Activity fixture autoplay."
            }
        }
    }

    static func data(named name: String) throws -> Data {
        guard let file = Bundle.main.url(forResource: name, withExtension: "apns", subdirectory: "ActivityFixtures")
        else { throw Failure.missingFixture }
        return try Data(contentsOf: file)
    }

    static func decode(_ data: Data, at date: Date) throws -> ChannelActivityPush {
        let push = try JSONDecoder().decode(ChannelActivityPush.self, from: data).reanchored(at: date)
        guard (push.event == .end) == (push.state.ending != nil), push.staleDate == push.state.staleDate
        else { throw Failure.invalidEnvelope }
        return push
    }

    static func startLocal(_ data: Data, attributes: ChannelActivityAttributes, at date: Date = .now) throws -> String {
        let push = try decode(data, at: date)
        guard push.event == .update else { throw Failure.needsUpdate }
        return try Activity<ChannelActivityAttributes>.request(
            attributes: attributes, content: .init(state: push.state, staleDate: push.staleDate), pushType: nil
        ).id
    }

    static func apply(_ data: Data, activityID: String, registrationID: String,
                      at date: Date = .now, client: ChannelActivityClient = .system) async throws -> ChannelActivityPush {
        let push = try decode(data, at: date)
        guard let activity = client.activities().first(where: {
            $0.id == activityID && $0.attributes.registrationID == registrationID && $0.isActive
        }) else { throw Failure.unavailableActivity }
        switch push.event {
        case .update:
            await activity.update(push.state)
        case .end:
            await activity.end(push.state, dismissAt: push.dismissalDate)
        }
        return push
    }

    static func autoplay(endedOnly: Bool,
                         apply: (String) async throws -> Void,
                         pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        let states = endedOnly ? ["ended"] : ["working", "quiet", "request", "stale", "completed"]
        for (index, state) in states.enumerated() {
            try Task.checkCancellation()
            try await apply(state)
            if index < states.count - 1 { try await pause(.seconds(2)) }
        }
    }

    static func withBackgroundTime(
        waitForBackground: () async throws -> Void,
        beginBackgroundTask: (_ expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: "Activity fixture autoplay", expirationHandler: $0)
        },
        endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) },
        run: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await waitForBackground()
        try Task.checkCancellation()
        let operation = BackgroundOperation()
        let background = beginBackgroundTask {
            operation.expired = true
            operation.task?.cancel()
        }
        guard background != .invalid else { throw Failure.backgroundTimeUnavailable }
        defer { endBackgroundTask(background) }
        let task = Task {
            try Task.checkCancellation()
            try await run()
        }
        operation.task = task
        if operation.expired { task.cancel() }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @MainActor
    private final class BackgroundOperation {
        var task: Task<Void, any Error>?
        var expired = false
    }

    struct AutoplayStatus: Codable {
        enum Phase: String, Codable { case ready, applied, finished, failed }
        let phase: Phase
        let activityID: String?
        let state: String?
        let updatedAt: Date
        let error: String?
    }

    static func autoplayStatusURL() throws -> URL {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appending(path: "Automation", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "activity-fixture-autoplay.json")
    }
}

@MainActor
struct ActivityFixtureProofView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var activityID: String?
    @ViewState private var isApplying = false
    @ViewState private var result = "No fixture Activity started"
    @ViewState private var autoplayStarted = false
    @ViewState private var autoplayState: String?
    private let logger = Logger(subsystem: "dev.toybox.mobile", category: "ActivityFixtureProof")

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(result).accessibilityIdentifier("activity-fixture-result")
                    Button("Start Fixture Activity (No Push Token)") { apply(nil) }
                        .disabled(activityID != nil)
                    ForEach(["working", "quiet", "request", "completed", "ended", "stale"], id: \.self) { state in
                        Button("Apply \(state.capitalized) Fixture") { apply(state) }
                            .disabled(activityID == nil)
                    }
                } footer: {
                    Text("Presentation only. Decodes APNs fixtures through ActivityKit without registering Follow or delivering a push.")
                }
                .disabled(isApplying)
            }
            .navigationTitle("Activity Fixture Proof")
        }
        .task(id: model.notifications.hasLoadedAuthorization ? model.notifications.currentRegistration?.registrationID : nil) {
            guard ProcessInfo.processInfo.arguments.contains("--autoplay"), !autoplayStarted else { return }
            guard model.notifications.hasLoadedAuthorization, model.notifications.currentRegistration != nil else {
                result = "Waiting for local integration startup"
                return
            }
            autoplayStarted = true
            await runAutoplay()
        }
    }

    private func demoAttributes() async throws -> ChannelActivityAttributes {
        guard let api = model.catalog?.api, let registration = model.notifications.currentRegistration,
              ["localhost", "127.0.0.1", "::1"].contains(api.baseURL.host ?? ""), api.baseURL.port == 3210
        else { throw MobileActivityFixtureProof.Failure.notDemoServer }
        let catalog = try await api.catalog()
        guard let channel = catalog.channels.first(where: { $0.id == "studio-demo" })
        else { throw MobileActivityFixtureProof.Failure.missingDemoChannel }
        guard model.notifications.currentRegistration == registration
        else { throw MobileActivityFixtureProof.Failure.notDemoServer }
        return .init(channelID: channel.id, channelName: channel.name, registrationID: registration.registrationID)
    }

    private func waitForApplicationState(_ state: UIApplication.State) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while UIApplication.shared.applicationState != state {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw state == .active ? MobileActivityFixtureProof.Failure.needsForeground
                    : MobileActivityFixtureProof.Failure.needsBackground
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func publishAutoplay(_ phase: MobileActivityFixtureProof.AutoplayStatus.Phase,
                                 error: String? = nil) throws {
        let status = MobileActivityFixtureProof.AutoplayStatus(
            phase: phase, activityID: activityID, state: autoplayState, updatedAt: .now, error: error
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(status).write(to: MobileActivityFixtureProof.autoplayStatusURL(), options: .atomic)
    }

    private func runAutoplay() async {
        isApplying = true
        defer { isApplying = false }
        do {
            try Task.checkCancellation()
            let attributes = try await demoAttributes()
            try await waitForApplicationState(.active)
            try Task.checkCancellation()
            let statusURL = try MobileActivityFixtureProof.autoplayStatusURL()
            if FileManager.default.fileExists(atPath: statusURL.path) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                let previous = try decoder.decode(MobileActivityFixtureProof.AutoplayStatus.self, from: Data(contentsOf: statusURL))
                if let activity = ChannelActivityClient.system.activities().first(where: {
                    $0.id == previous.activityID && $0.attributes.registrationID == attributes.registrationID
                }) {
                    await activity.end(activity.content, dismissAt: nil)
                }
            }
            let working = try MobileActivityFixtureProof.data(named: "push-activity-working")
            activityID = try MobileActivityFixtureProof.startLocal(working, attributes: attributes)
            result = "Autoplay ready. Return Home or lock the simulator. No push token or Follow registration."
            try publishAutoplay(.ready)
            try await MobileActivityFixtureProof.withBackgroundTime(
                waitForBackground: { try await waitForApplicationState(.background) }
            ) {
                do {
                    try await MobileActivityFixtureProof.autoplay(
                        endedOnly: ProcessInfo.processInfo.arguments.contains("--autoplay-ended"),
                        apply: { state in
                            guard model.notifications.currentRegistration?.registrationID == attributes.registrationID,
                                  let activityID else { throw MobileActivityFixtureProof.Failure.unavailableActivity }
                            let name = state == "request" ? "push-activity" : "push-activity-\(state)"
                            let data = try MobileActivityFixtureProof.data(named: name)
                            _ = try await MobileActivityFixtureProof.apply(
                                data, activityID: activityID, registrationID: attributes.registrationID
                            )
                            autoplayState = state
                            result = "Autoplay applied \(state) fixture"
                            try publishAutoplay(.applied)
                        }
                    )
                    result = "Autoplay finished. The terminal card keeps its fixture dismissal date."
                    try publishAutoplay(.finished)
                } catch {
                    await failAutoplay(error)
                }
            }
        } catch {
            await failAutoplay(error)
        }
    }

    private func failAutoplay(_ error: any Error) async {
        result = "Autoplay failed: \(error.localizedDescription)"
        logger.error("\(result)")
        if let activity = ChannelActivityClient.system.activities().first(where: { $0.id == activityID }) {
            await activity.end(activity.content, dismissAt: nil)
        }
        do { try publishAutoplay(.failed, error: error.localizedDescription) }
        catch { logger.error("Could not write autoplay status: \(error.localizedDescription)") }
    }

    private func apply(_ state: String?) {
        isApplying = true
        Task {
            defer { isApplying = false }
            do {
                guard let api = model.catalog?.api, let registration = model.notifications.currentRegistration,
                      ["localhost", "127.0.0.1", "::1"].contains(api.baseURL.host ?? ""), api.baseURL.port == 3210
                else { throw MobileActivityFixtureProof.Failure.notDemoServer }
                let name = state == "request" ? "push-activity" : "push-activity-\(state ?? "working")"
                let data = try MobileActivityFixtureProof.data(named: name)
                if let state {
                    guard let activityID else { throw MobileActivityFixtureProof.Failure.unavailableActivity }
                    let push = try await MobileActivityFixtureProof.apply(
                        data, activityID: activityID, registrationID: registration.registrationID
                    )
                    if push.event == .end { self.activityID = nil }
                    result = "Applied \(state) fixture"
                } else {
                    activityID = try MobileActivityFixtureProof.startLocal(data, attributes: try await demoAttributes())
                    result = "Local working fixture started. No push token or Follow registration."
                }
            } catch {
                if let failure = error as? MobileActivityFixtureProof.Failure, case .unavailableActivity = failure {
                    activityID = nil
                }
                result = "Fixture failed: \(error.localizedDescription)"
            }
        }
    }
}
#endif

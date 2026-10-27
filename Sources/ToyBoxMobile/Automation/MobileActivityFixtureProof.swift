#if DEBUG && targetEnvironment(simulator)
import ActivityKit
import ChannelKit
import Foundation
import SwiftUI

@MainActor
enum MobileActivityFixtureProof {
    enum Failure: LocalizedError {
        case missingFixture, invalidEnvelope, needsUpdate, unavailableActivity, notDemoServer, missingDemoChannel

        var errorDescription: String? {
            switch self {
            case .missingFixture: "The debug bundle is missing its Activity fixture."
            case .invalidEnvelope: "The Activity fixture's event or freshness does not match its state."
            case .needsUpdate: "Start the local proof with an active Activity fixture."
            case .unavailableActivity: "Start a local fixture Activity for the current registration first."
            case .notDemoServer: "Connect to the local demo server on port 3210 first."
            case .missingDemoChannel: "The demo server has no studio-demo channel."
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
}

@MainActor
struct ActivityFixtureProofView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var activityID: String?
    @ViewState private var isApplying = false
    @ViewState private var result = "No fixture Activity started"

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
                    let catalog = try await api.catalog()
                    guard let channel = catalog.channels.first(where: { $0.id == "studio-demo" })
                    else { throw MobileActivityFixtureProof.Failure.missingDemoChannel }
                    guard model.notifications.currentRegistration == registration
                    else { throw MobileActivityFixtureProof.Failure.notDemoServer }
                    activityID = try MobileActivityFixtureProof.startLocal(data, attributes: .init(
                        channelID: channel.id, channelName: channel.name, registrationID: registration.registrationID
                    ))
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

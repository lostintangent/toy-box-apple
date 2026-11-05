import ChannelKit
import Foundation
import Testing
@testable import ChannelClient

/// The text Siri reads for the channel or artifact on screen, on both apps.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ReadableTextTests {
    @Test func aChannelReadsAsItsPurposeTasksAndConversation() throws {
        let channel = Channel(
            id: "launch", name: "Launch", purpose: "Ship **the** app", model: .init(provider: "test", name: "test"),
            tasks: [ChannelTask(id: "plan", title: "Plan", status: "in_progress",
                                children: [ChannelTask(id: "draft", title: "Draft", status: "done")])],
            updatedAt: "2026-11-05T12:00:00Z")
        let request = ChannelMessage(id: "m4", sequence: 4, timestamp: "2026-11-05T12:03:00Z", sender: .agent("lead"),
                                     content: .text("Ship it?"), request: true)
        let store = try store(channel, messages: [
            ChannelMessage(id: "m1", sequence: 1, timestamp: "2026-11-05T12:00:00Z", sender: .user,
                           content: .text("Can you **check** the build?")),
            ChannelMessage(id: "m3", sequence: 3, timestamp: "2026-11-05T12:02:00Z", sender: .agent("core"),
                           content: .text("Done, see `report.md`"),
                           attachments: [ChannelAttachment(name: "report.md", mimeType: "text/markdown")]),
            request,
        ], request: request)

        #expect(store.readableText(name: "Launch") == """
            Channel: Launch
            Purpose: Ship the app

            Tasks:
            - Plan (in progress)
              - Draft (done)

            Messages, oldest first:
            You: Can you check the build?

            Core: Done, see report.md (attached report.md)

            Lead (waiting for your reply): Ship it?
            """)
    }

    @Test func aChannelKeepsTheNewestMessagesThatFitWithTheWaitingRequest() throws {
        let words = Array(repeating: "word", count: 400).joined(separator: " ")
        let request = ChannelMessage(id: "m1", sequence: 1, timestamp: "2026-11-05T12:00:00Z", sender: .agent("lead"),
                                     content: .text("Which release?"), request: true)
        let messages = [request] + (2...60).map {
            ChannelMessage(id: "m\($0)", sequence: $0, timestamp: "2026-11-05T12:00:00Z", sender: .user,
                           content: .text("Message \($0) \(words)"))
        }
        let store = try store(
            Channel(id: "launch", name: "Launch", model: .init(provider: "test", name: "test"),
                    updatedAt: "2026-11-05T12:00:00Z"),
            messages: messages, request: request)
        let text = store.readableText(name: "Launch")
        let lines = text.components(separatedBy: "\n\n")
        #expect(text.count <= ChannelStore.readableTextLimit)
        #expect(lines.contains("Messages, oldest first:\nLead (waiting for your reply): Which release?"))
        #expect(lines.last?.hasPrefix("You: Message 60 word") == true)
        #expect(!text.contains("Message 2 word"))
        #expect(lines.filter { $0.hasPrefix("You: ") }.allSatisfy {
            $0.count <= "You: ".count + ChannelStore.readableMessageLimit && $0.hasSuffix("\u{2026}")
        })
    }

    @Test func onlyAnOpenMarkdownArtifactHasText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("readable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# Plan\n\nShip **it** today.".utf8).write(to: directory.appendingPathComponent("plan.md"))
        try Data("<html><script>track()</script><p>Page</p></html>".utf8)
            .write(to: directory.appendingPathComponent("page.html"))
        let session = ChannelArtifactSession(decodeImage: { _, _, _ in throw ChannelAttachmentError.invalidImage },
                                             download: { artifact, _ in directory.appendingPathComponent(artifact.file.path) })
        defer { session.close() }
        let plan = ChannelArtifact(file: .init(kind: "machine", path: "plan.md"), title: "Plan",
                                   url: "/api/serve/launch/plan.md")
        let page = ChannelArtifact(file: .init(kind: "machine", path: "page.html"), title: "Page",
                                   url: "/api/serve/launch/page.html")
        session.configure(api: try ChannelAPI(serverURL: "https://fixture.example"), channelID: "launch",
                          artifacts: [plan, page])
        #expect(session.readableText == "")

        session.open(plan)
        await session.loadTask?.value
        #expect(session.readableText == "Plan\nShip it today.")

        #expect(session.select(page.id))
        await session.loadTask?.value
        // HTML is the raw page, scripts and all.
        #expect(session.content?.text != nil)
        #expect(session.readableText == "")

        session.close()
        #expect(session.readableText == "")
    }

    private func store(_ channel: Channel, messages: [ChannelMessage], request: ChannelMessage?) throws -> ChannelStore {
        let store = ChannelStore(id: channel.id, api: try ChannelAPI(serverURL: "https://fixture.example"), sendJournal: nil)
        _ = try store.apply(.init(type: "snapshot", state: ChannelState(
            revision: 1, channel: channel,
            lead: .lead(id: "lead", profile: .init(name: "Lead", role: "Coordinator",
                                                  avatar: .init(mark: "M4 12H20", color: "#123456"))),
            members: [ChannelAgent(id: "core", name: "Core")],
            messages: messages, request: request)))
        return store
    }
}

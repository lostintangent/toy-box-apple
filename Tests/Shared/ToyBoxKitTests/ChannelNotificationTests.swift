import Testing
@testable import ToyBoxKit

struct ChannelNotificationTests {
    private let agents = [ChannelAgent(id: "lead", name: "Lead"), ChannelAgent(id: "ada", name: "Ada Lovelace")]

    private func requestBody(_ text: String, attachments: [ChannelAttachment]? = nil) -> String {
        let message = ChannelMessage(id: "m12", sequence: 12, timestamp: "2026-10-22T08:00:00Z",
                                     sender: .init(type: "agent", agentId: "ada"), content: .text(text),
                                     request: true, attachments: attachments)
        return ChannelNotification.Content(request: ChannelRequestMessage(message: message, agents: agents)).body
    }

    private func channel(_ id: String, request: Int? = nil, seen: Int = 10) -> Channel {
        Channel(id: id, name: id, model: .init(provider: "test", name: "test"), latestSequence: 20,
                seenThrough: seen, requestSequence: request, updatedAt: "2026-10-22T08:00:00Z")
    }

    @Test func attachmentOnlyRequestsSayWhatWasSent() {
        let image = ChannelAttachment(name: "door.png", mimeType: "image/png")
        let file = ChannelAttachment(name: "notes.pdf", mimeType: "application/pdf")
        #expect(requestBody("@lead", attachments: [image]) == "Sent an image")
        #expect(requestBody("", attachments: [image, image, image]) == "Sent 3 images")
        #expect(requestBody("", attachments: [file]) == "Sent a file")
        #expect(requestBody("", attachments: [image, file]) == "Sent 2 files")
        #expect(requestBody("  ") == ChannelNotification.Content.waitingBody)
    }

    @Test func longRequestsCutAtAWordBoundary() {
        let text = String(repeating: "entrance ", count: 60)
        let body = ChannelNotification.Content.truncated(text)
        #expect(body.count <= ChannelNotification.Content.bodyLimit)
        #expect(body.hasSuffix("entrance\u{2026}"))
        #expect(ChannelNotification.Content.truncated("Short and sweet.") == "Short and sweet.")
        #expect(ChannelNotification.Content.truncated(String(repeating: "a", count: 500)).count
            == ChannelNotification.Content.bodyLimit)
    }

    @Test func repliesAreAddressedLikeTheInAppReply() {
        #expect(ChannelNotification.Reply("  Ship it  ", to: "ada-lovelace")?.content == "@ada-lovelace Ship it")
        #expect(ChannelNotification.Reply("@lead Ship it", to: "ada-lovelace")?.content == "@lead Ship it")
        #expect(ChannelNotification.Reply("Ship it", to: nil)?.content == "Ship it")
        #expect(ChannelNotification.Reply(" \n ", to: "ada-lovelace") == nil)
    }

    @Test func notificationsWithdrawOnceTheyStopBeingTrue() {
        func delivered(_ channel: String, _ kind: String, _ sequence: Int, server: String = "s") -> ChannelNotification.Delivered {
            .init(identifier: "\(server):\(channel):\(kind):\(sequence)", scope: server, channelID: channel,
                  kind: ChannelPushPayload.Kind(rawValue: kind), sequence: sequence)
        }
        let items = [delivered("answered", "request", 11), delivered("waiting", "request", 12),
                     delivered("seen", "completion", 9), delivered("unseen", "completion", 15),
                     delivered("active", "completion", 15), delivered("active", "replyFailed", 0),
                     delivered("waiting", "replyFailed", 0), delivered("deleted", "request", 4),
                     delivered("answered", "request", 11, server: "other")]
        let channels = [channel("answered"), channel("waiting", request: 12), channel("seen"),
                        channel("unseen"), channel("active")]
        #expect(Set(ChannelNotification.Delivered.stale(items, channels: channels, scope: "s", activeChannelID: "active"))
            == ["s:answered:request:11", "s:seen:completion:9", "s:active:completion:15",
                "s:active:replyFailed:0", "s:deleted:request:4"])
    }
}

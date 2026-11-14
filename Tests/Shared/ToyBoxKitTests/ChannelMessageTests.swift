import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ChannelKit

struct ChannelMessageTests {
    @Test func agentCountsExcludeUsersSystemRowsAndOtherSendersAtTheExactBoundary() {
        let messages = [message(1, .agent("lead")), message(2, .user), message(3, .system),
                        message(4, .agent("member")), message(5, .init(type: "other"))]
        #expect(messages.agentMessageCount() == 2)
        for (boundary, count) in [(0, 2), (1, 1), (3, 1), (4, 0), (5, 0)] {
            #expect(messages.agentMessageCount(after: boundary) == count)
        }
        #expect([ChannelMessage]().agentMessageCount() == 0)
    }

    @Test func unnamedImagesAreNamedByPositionAndDataURLsNeverNameAFile() {
        let inline = ChannelAttachment(url: "data:image/png;base64,iVBORw0KGgo=", mimeType: "image/png")
        #expect(inline.filename == nil)
        #expect(inline.displayName == "Image")
        #expect(inline.imageName(index: 1, count: 3) == "Image 2 of 3")
        #expect(inline.imageName(index: 0, count: 1) == "Image")
        let remote = ChannelAttachment(url: "http://localhost:3210/files/plan.png", mimeType: "image/png")
        #expect(remote.imageName(index: 0, count: 2) == "plan.png")
        #expect(ChannelAttachment().displayName == "Attachment")
        #expect(ChannelAttachment(name: "", url: "/files/plan%20one.png").filename == "plan one.png")
        #expect(ChannelAttachment(name: "Own name", url: "/files/other.png").filename == "Own name")
        #expect(ChannelAttachment(url: "https://server.test/").filename == nil)
        #expect(ChannelAttachment(name: " ").filename == " ")
    }

    @Test func attachmentTypesPreferMIMEThenFilenameAndRecognizeSVG() {
        let pdf = ChannelAttachment(name: "misleading.png", mimeType: "application/pdf")
        #expect(pdf.contentType == .pdf)
        #expect(!pdf.isImage)
        #expect(ChannelAttachment(name: "drawing.svg").isImage)
        #expect(ChannelAttachment(mimeType: "image/svg+xml").isImage)
        #expect(ChannelAttachment(url: "/files/photo.png").isImage)
        #expect(ChannelAttachment().contentType == nil)
        #expect(!ChannelAttachment().isImage)
    }

    /// Newest first, with a placeholder for a message that hasn't loaded or that the server would
    /// never bookmark, and the first message wins when an unconfirmed send shares its sequence.
    @Test func bookmarksListNewestFirstAndResolveOnlyLoadedConversationMessages() {
        var confirmed = message(4, .user)
        confirmed.content = .text("Confirmed")
        let pending = ChannelMessage(id: "pending", sequence: 4, timestamp: "2026-10-24T08:00:00Z",
                                     sender: .user, content: .text("Pending"))
        let system = ChannelMessage(id: "3", sequence: 3, timestamp: "2026-10-24T08:00:00Z",
                                    sender: .system, content: .system(.init(type: "member_added")))
        let messages = [message(2, .agent("lead")), system, confirmed, pending]
        let list = ChannelBookmark.list([1, 2, 3, 4], in: messages)
        #expect(list.map(\.id) == [4, 3, 2, 1])
        #expect(list.map(\.message) == [confirmed, nil, messages[0], nil])
        #expect(list.map { $0.preview(agents: []) } == ["Confirmed", nil, "Update", nil])
        #expect(ChannelBookmark.list([], in: messages).isEmpty)
    }

    /// The first line of plain text, like a notification's, or the attachment count without words.
    /// An agent's leading mentions drop out like the transcript's, and the user's stay.
    @Test func bookmarkPreviewsTheFirstPlainLineOrCountsAttachments() {
        let agents = [ChannelAgent(id: "ada", name: "Ada"), ChannelAgent(id: "pixel", name: "Pixel")]
        func preview(_ text: String, attachments: Int = 0, from sender: ChannelMessageSender = .user) -> String? {
            var message = message(1, sender)
            message.content = .text(text)
            message.attachments = attachments == 0 ? nil : Array(repeating: ChannelAttachment(), count: attachments)
            return ChannelBookmark(sequence: 1, message: message).preview(agents: agents)
        }
        #expect(preview("@ada @pixel Connect the **public** transcript", from: .agent("lead"))
                == "Connect the public transcript")
        // The transcript keeps a message that's only mentions, so the preview does too.
        #expect(preview("@ada", attachments: 1, from: .agent("lead")) == "@ada")
        #expect(preview("@stranger Connect it", from: .agent("lead")) == "@stranger Connect it")
        #expect(preview("@ada Connect it") == "@ada Connect it")
        #expect(preview("## Plan\n\nShip **it**") == "Plan")
        #expect(preview("[Docs](https://example.com) are up\nSecond line") == "Docs are up")
        #expect(preview("\n- first\n- second") == "\u{2022} first")
        #expect(preview("", attachments: 1) == "1 attachment")
        #expect(preview("  \n---\n", attachments: 2) == "2 attachments")
        #expect(preview("") == "0 attachments")
    }

    private func message(_ sequence: Int, _ sender: ChannelMessageSender) -> ChannelMessage {
        .init(id: "\(sequence)", sequence: sequence, timestamp: "2026-10-24T08:00:00Z",
              sender: sender, content: .text("Update"))
    }
}

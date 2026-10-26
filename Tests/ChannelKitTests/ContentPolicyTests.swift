import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ChannelKit

struct ContentPolicyTests {
    @Test func agentCountsExcludeUsersSystemRowsAndOtherSendersAtTheExactBoundary() {
        let messages = [message(1, .agent("lead")), message(2, .user), message(3, .system),
                        message(4, .agent("member")), message(5, .init(type: "other"))]
        #expect(messages.map(\.isAgentMessage) == [true, false, false, true, false])
        #expect(channelAgentMessageCount(messages) == 2)
        for (boundary, count) in [(0, 2), (1, 1), (3, 1), (4, 0), (5, 0)] {
            #expect(channelAgentMessageCount(messages, after: boundary) == count)
        }
        #expect(channelAgentMessageCount([]) == 0)
    }

    @Test func everyCommonSendBlockerAndTheUTF16LimitIsPreserved() {
        let atLimit = String(repeating: "\u{1F680}", count: 6_000).utf16.count
        #expect(atLimit == 12_000)
        for blockers in 0..<64 {
            for length in [0, 11_999, atLimit, atLimit + 1] {
                let eligible = channelCanSend(
                    isLive: blockers & 1 == 0,
                    isSending: blockers & 2 != 0,
                    isSubmitting: blockers & 4 != 0,
                    hasContent: blockers & 8 == 0,
                    isLoadingImages: blockers & 16 != 0,
                    hasUnreadableImage: blockers & 32 != 0,
                    textUTF16Count: length)
                #expect(eligible == (blockers == 0 && length <= 12_000))
            }
        }
    }

    @Test func purposePreviewKeepsTheOriginalFirstLineSemantics() {
        #expect(channelPurposePreview("  Ship the demo  \nThen the docs") == "Ship the demo")
        #expect(channelPurposePreview("\n\nFirst\r\nSecond") == "First")
        #expect(channelPurposePreview(" \nSecond") == nil)
        #expect(channelPurposePreview("\n\t\nSecond") == nil)
        #expect(channelPurposePreview("") == nil)
        #expect(channelPurposePreview(nil) == nil)
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

    private func message(_ sequence: Int, _ sender: ChannelMessageSender) -> ChannelMessage {
        .init(id: "\(sequence)", sequence: sequence, timestamp: "2026-10-24T08:00:00Z",
              sender: sender, content: .text("Update"))
    }
}

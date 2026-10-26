import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ChannelKit

struct ContentPolicyTests {
    @Test func agentCountsExcludeUsersSystemRowsAndOtherSendersAtTheExactBoundary() {
        let messages = [message(1, .agent("lead")), message(2, .user), message(3, .system),
                        message(4, .agent("member")), message(5, .init(type: "other"))]
        #expect(channelAgentMessageCount(messages) == 2)
        for (boundary, count) in [(0, 2), (1, 1), (3, 1), (4, 0), (5, 0)] {
            #expect(channelAgentMessageCount(messages, after: boundary) == count)
        }
        #expect(channelAgentMessageCount([]) == 0)
    }

    @Test func sendEligibilityStopsAtEachBlockerAndKeepsTheLengthBoundary() {
        let inputs = ["isLive", "isSending", "isSubmitting", "hasContent",
                      "isLoadingImages", "hasUnreadableImage", "textUTF16Count"]
        let cases = (0..<6).map { (blocker: $0, length: 12_001, allowed: false) } + [
            (blocker: 6, length: 0, allowed: true),
            (blocker: 6, length: 17, allowed: true),
            (blocker: 6, length: 12_000, allowed: true),
            (blocker: 6, length: 12_001, allowed: false),
        ]
        for example in cases {
            var reads: [String] = []
            func read(_ index: Int, _ value: Bool) -> Bool {
                reads.append(inputs[index])
                return value
            }
            func readLength() -> Int {
                reads.append(inputs[6])
                return example.length
            }
            let eligible = channelCanSend(
                isLive: read(0, example.blocker != 0),
                isSending: read(1, example.blocker == 1),
                isSubmitting: read(2, example.blocker == 2),
                hasContent: read(3, example.blocker != 3),
                isLoadingImages: read(4, example.blocker == 4),
                hasUnreadableImage: read(5, example.blocker == 5),
                textUTF16Count: readLength())
            #expect(eligible == example.allowed)
            #expect(reads == Array(inputs.prefix(example.blocker + 1)))
        }
    }

    @Test func purposePreviewKeepsTheOriginalFirstLineSemantics() {
        #expect(channelPurposePreview("  Ship the demo  \nThen the docs") == "Ship the demo")
        #expect(channelPurposePreview("\n\nFirst\r\nSecond") == "First")
        #expect(channelPurposePreview(" \nSecond") == nil)
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

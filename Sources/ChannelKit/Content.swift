import Foundation
import UniformTypeIdentifiers

extension ChannelMessage {
    public var isAgentMessage: Bool { !isSystem && sender.type == "agent" }
}

public func channelAgentMessageCount(_ messages: [ChannelMessage], after sequence: Int? = nil) -> Int {
    messages.count { message in
        message.isAgentMessage && (sequence.map { message.sequence > $0 } ?? true)
    }
}

public func channelCanSend(isLive: Bool, isSending: Bool, isSubmitting: Bool, hasContent: Bool,
                           isLoadingImages: Bool, hasUnreadableImage: Bool, textUTF16Count: Int) -> Bool {
    isLive && !isSending && !isSubmitting && hasContent && !isLoadingImages
        && !hasUnreadableImage && textUTF16Count <= 12_000
}

public func channelPurposePreview(_ text: String?) -> String? {
    let line = text?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces)
    return line?.isEmpty == false ? line : nil
}

extension ChannelAttachment {
    public var filename: String? {
        if let name, !name.isEmpty { return name }
        guard let url, !url.hasPrefix("data:"),
              let component = URL(string: url)?.lastPathComponent,
              !component.isEmpty, component != "/" else { return nil }
        return component
    }

    public var displayName: String {
        filename ?? (mimeType?.hasPrefix("image/") == true ? "Image" : "Attachment")
    }

    public func imageName(index: Int, count: Int) -> String {
        filename ?? (count > 1 ? "Image \(index + 1) of \(count)" : "Image")
    }

    public var contentType: UTType? {
        mimeType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: (displayName as NSString).pathExtension)
    }

    public var isImage: Bool { contentType?.conforms(to: .image) == true }
}

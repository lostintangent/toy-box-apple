import AppKit
import ChannelClient

extension ComposerImage {
    var image: NSImage? { NSImage(data: data) }
}

extension ComposerDraft {
    convenience init(fileURL: URL? = nil) {
        self.init(fileURL: fileURL, imageIsReadable: isReadableComposerImage)
    }

    static func shared(serverURL: URL, channelID: String, scope: Scope = .conversation) -> ComposerDraft {
        shared(serverURL: serverURL, channelID: channelID, scope: scope, imageIsReadable: isReadableComposerImage)
    }
}

private func isReadableComposerImage(_ data: Data) -> Bool { NSImage(data: data) != nil }

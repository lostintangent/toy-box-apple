import ChannelClient
import UIKit
import UniformTypeIdentifiers

@MainActor
enum DraftPasteboard {
    static func copy(_ draft: ComposerDraft) {
        UIPasteboard.general.itemProviders = itemProviders(for: draft)
    }

    static func itemProviders(for draft: ComposerDraft) -> [NSItemProvider] {
        var providers = draft.text.isEmpty ? [] : [NSItemProvider(object: draft.text as NSString)]
        for image in draft.images {
            let type = UTType(mimeType: image.mimeType) ?? .data
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                completion(image.data, nil)
                return nil
            }
            provider.suggestedName = image.name
            providers.append(provider)
        }
        return providers
    }
}

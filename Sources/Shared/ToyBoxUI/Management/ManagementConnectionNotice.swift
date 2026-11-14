import ToyBoxClient
import SwiftUI

/// Why a management sheet can't save yet, shown only while its channel is unavailable.
public struct ManagementConnectionNotice: View {
    let store: ChannelStore?

    public init(store: ChannelStore?) { self.store = store }

    public var body: some View {
        if let store, store.phase.isUnavailable {
            Label(store.phase == .deleted ? "This channel was deleted."
                  : "Your edits are kept. Save them when the channel connects.",
                  systemImage: "wifi.exclamationmark")
                #if os(macOS)
                .font(.callout)
                #else
                .font(.footnote)
                #endif
                .foregroundStyle(ChannelInk.secondary)
        }
    }
}

import ChannelClient
import SwiftUI

struct ComposerView: View {
    let store: ChannelStore

    var body: some View {
        ComposerSurface(session: .shared(store: store))
            .id(ObjectIdentifier(store))
    }
}

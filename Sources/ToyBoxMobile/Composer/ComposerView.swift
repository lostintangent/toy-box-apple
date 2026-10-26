import ChannelClient
import SwiftUI

struct ComposerView: View {
    let store: ChannelStore
    let showsTray: Bool
    @Environment(AppModel.self) private var app

    init(store: ChannelStore, showsTray: Bool = true) {
        self.store = store
        self.showsTray = showsTray
    }

    var body: some View {
        ComposerSurface(session: app.composerSession(for: store), showsTray: showsTray)
            .id(ObjectIdentifier(store))
    }
}

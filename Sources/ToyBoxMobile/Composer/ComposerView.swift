import ChannelClient
import SwiftUI

struct ComposerView: View {
    let store: ChannelStore
    @Environment(AppModel.self) private var app

    var body: some View {
        ComposerSurface(session: app.composerSession(for: store))
            .id(ObjectIdentifier(store))
    }
}

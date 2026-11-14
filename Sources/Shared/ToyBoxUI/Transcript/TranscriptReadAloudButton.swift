import ChannelClient
import SwiftUI

/// Read Aloud beside Reply, which shows Stop Reading while its request is read.
struct TranscriptReadAloudButton: View {
    let request: TranscriptReadAloud.Request
    private var reader: TranscriptReadAloud { .shared }

    var body: some View {
        let isReading = reader.isReading(request)
        Button { reader.toggle(request) } label: {
            Label {
                Text(isReading ? "Stop Reading" : "Read Aloud")
            } icon: {
                // A symbol in text takes the line's height, so the pill matches Reply's.
                Text(Image(systemName: isReading ? "stop.fill" : "speaker.wave.2"))
            }
        }
        .labelStyle(.iconOnly)
        .disabled(reader.isMicrophoneOpen)
        .help(isReading ? "Stop Reading" : "Read Aloud")
        .accessibilityIdentifier("read-aloud-\(request.sequence)")
    }
}

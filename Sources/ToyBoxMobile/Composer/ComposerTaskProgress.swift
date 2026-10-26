import ChannelClient
import ChannelKit
import SwiftUI

struct ComposerTaskProgress: View {
    let store: ChannelStore
    let showTasks: () -> Void

    var body: some View {
        let tray = ChannelTrayProjection(
            artifacts: store.artifacts, tasks: store.tasks, preview: store.details?.resolvedPreview)
        if tray.hasTasks {
            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    Button(action: showTasks) {
                        Label("\(tray.taskProgress.done)/\(tray.taskProgress.total)", systemImage: "checklist")
                            .lineLimit(1)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                    .foregroundStyle(Color.primary)
                    .accessibilityLabel("Tasks")
                    .accessibilityValue("\(tray.taskProgress.done) of \(tray.taskProgress.total) done")
                    .accessibilityIdentifier("composer-task-progress")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().padding(.horizontal, 12)
            }
        }
    }
}

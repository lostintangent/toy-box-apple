import SwiftUI

/// The composer's Dictate button. It is styled like Attach Image and never becomes a second filled control.
struct DictateButton: View {
    @Bindable var dictation: ComposerDictation
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if dictation.availability != .unsupported, dictation.availability != .checking {
            Button(action: action) {
                label.contentShape([.interaction, .accessibility], Circle())
            }
                .buttonStyle(.borderless)
                .disabled(dictation.availability == .noMicrophone && dictation.phase == .idle)
                .help(help)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(dictation.phase == .idle && dictation.accessOff != nil ? "Access is off" : "")
                .popover(isPresented: $dictation.showsAccessExplanation, arrowEdge: .top) {
                    DictationAccessPopover(access: dictation.accessOff ?? .microphone,
                                           openSettings: dictation.openSettings)
                }
        }
    }

    @ViewBuilder private var label: some View {
        switch dictation.phase {
        case .downloading(let progress):
            ZStack {
                Circle().inset(by: 1).stroke(Color.primary.opacity(0.12), lineWidth: 2)
                Circle().inset(by: 1)
                    .trim(from: 0, to: max(progress, 0.02))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "mic").font(.system(size: 10))
            }
            .frame(width: 22, height: 22)
            .frame(width: 28, height: 28)
        case .listening, .finishing:
            Image(systemName: "waveform", variableValue: reduceMotion ? 1 : dictation.level)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.15), in: Circle())
        case .idle, .preparing:
            Image(systemName: dictation.accessOff == nil ? "mic" : "mic.slash")
                .frame(width: 28, height: 28)
        }
    }

    private var help: String {
        switch dictation.phase {
        case .listening, .finishing: return "Stop Dictation"
        case .downloading: return "Downloading dictation. Click to cancel."
        case .idle, .preparing:
            if let access = dictation.accessOff { return access.title }
            return dictation.availability == .noMicrophone ? "Connect a microphone to dictate" : "Dictate"
        }
    }

    private var accessibilityLabel: String {
        switch dictation.phase {
        case .listening, .finishing: "Stop Dictation"
        case .downloading: "Cancel Dictation Download"
        case .idle, .preparing: "Dictate"
        }
    }
}

struct DictationAccessPopover: View {
    let access: DictationAccess
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(access.title)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text(access.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Open System Settings", action: openSettings)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 280)
    }
}

import ChannelClient
import SwiftUI
import ToyBoxUI

struct ComposerDictateButton: View {
    @Bindable var dictation: ComposerDictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if dictation.availability != .checking, dictation.availability != .unsupported {
            Button { dictation.toggleRecheckingInput() } label: {
                label.frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(dictation.phase == .finishing
                      || dictation.availability == .noMicrophone && dictation.phase == .idle)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityShowsLargeContentViewer()
            .sheet(isPresented: $dictation.showsAccessExplanation) {
                if let access = dictation.accessOff {
                    NavigationStack {
                        Form {
                            Text(access.explanation)
                            Button("Open Settings") { dictation.openSettings() }
                        }
                        .navigationTitle(access.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Not Now") { dictation.showsAccessExplanation = false }
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        switch dictation.phase {
        case .downloading(let progress):
            ZStack {
                Circle().stroke(.primary.opacity(0.12), lineWidth: 2)
                Circle().trim(from: 0, to: progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "mic").font(.system(size: 10))
            }
            .frame(width: 22, height: 22)
        case .listening, .finishing:
            Image(systemName: "waveform", variableValue: reduceMotion ? 1 : dictation.level)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.15), in: Circle())
        case .idle, .preparing:
            Image(systemName: dictation.accessOff == nil ? "mic" : "mic.slash")
                .font(.system(size: 17))
                .foregroundStyle(ChannelInk.secondary)
        }
    }

    private var accessibilityLabel: String {
        switch dictation.phase {
        case .listening, .finishing: "Stop Dictation"
        case .downloading: "Cancel Dictation Download"
        case .preparing: "Cancel Dictation"
        case .idle:
            dictation.availability == .noMicrophone ? "Connect a microphone to dictate" : "Dictate"
        }
    }

    private var accessibilityValue: String {
        switch dictation.phase {
        case .downloading(let progress): progress.formatted(.percent.precision(.fractionLength(0)))
        case .listening: "Listening"
        case .finishing: "Finishing"
        case .idle, .preparing: dictation.accessOff == nil ? "" : "Access is off"
        }
    }
}

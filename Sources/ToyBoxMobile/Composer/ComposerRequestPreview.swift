import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct ComposerRequestPreviewState {
    struct Question: Equatable {
        let sequence: Int
        let text: String
    }

    private(set) var question: Question?
    private(set) var token: UUID?
    private(set) var outcome: RevealProgress.Outcome?
    private(set) var isPresented = false
    private var contextIsPresented = false
    private var wasDismissed = false

    mutating func begin(_ question: Question, token: UUID) {
        self.question = question
        self.token = token
        outcome = .loading
        wasDismissed = false
    }

    mutating func update(_ progress: RevealProgress?, requestSequence: Int, currentToken: UUID) {
        guard let question, let token else { return }
        guard question.sequence == requestSequence, token == currentToken else {
            invalidate()
            return
        }
        guard let progress, progress.token == token, progress.sequence == question.sequence else { return }
        outcome = progress.outcome
        switch progress.outcome {
        case .loading: break
        case .revealed:
            dismiss()
        case .failed:
            if !wasDismissed && !contextIsPresented { isPresented = true }
        }
    }

    mutating func contextAppeared() { contextIsPresented = true }

    mutating func contextDisappeared() {
        contextIsPresented = false
        if !isPresented { wasDismissed = true }
    }

    mutating func dismiss() {
        isPresented = false
        wasDismissed = true
    }

    mutating func invalidate() {
        let retained = isPresented ? question : nil
        self = Self()
        question = retained
    }
}

struct ComposerRequestButton: View {
    let request: ChannelMessage
    let allowsPresentation: Bool
    var willPresent: () -> Void
    var didDismiss: () -> Void
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ViewState private var preview = ComposerRequestPreviewState()

    private var outcome: RevealProgress.Outcome? {
        preview.question?.sequence == request.sequence ? preview.outcome : nil
    }
    private var isLoading: Bool { outcome == .loading }
    private var revealTitle: String {
        if case .failed = outcome { return "Retry Reveal" }
        return "Reveal in Conversation"
    }

    var body: some View {
        Button(action: reveal) {
            Label {
                Text("Input Needed").foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(ChannelAttentionStyle.color(for: .waiting, in: colorScheme))
            }
            .lineLimit(1).frame(minHeight: 44)
        }
        .font(.footnote)
        .buttonStyle(.borderless)
        .disabled(!allowsPresentation)
        .contextMenu {
            Button(revealTitle, action: reveal).disabled(isLoading)
                .menuActionDismissBehavior(.disabled)
        } preview: {
            content(question: request.text, interactive: false)
                .onAppear { preview.contextAppeared(); willPresent() }
                .onDisappear { preview.contextDisappeared(); didDismiss() }
        }
        .popover(isPresented: Binding(
            get: { preview.isPresented },
            set: { if !$0 { preview.dismiss() } }
        )) {
            if let question = preview.question {
                content(question: question.text, interactive: true)
                    .onDisappear { preview.dismiss(); didDismiss() }
            }
        }
        .onChange(of: interaction.revealProgress) { _, _ in synchronize() }
        .onChange(of: request.sequence) { _, _ in preview.invalidate() }
        .onChange(of: allowsPresentation) { _, allowed in if !allowed { preview.dismiss() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { synchronize() } }
        .onChange(of: preview.isPresented) { _, presented in if presented { willPresent() } }
        .onDisappear { preview.invalidate() }
        .accessibilityLabel("Input needed. Reveal the unanswered request.")
    }

    private func content(question: String, interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Input Needed").font(.headline)
                if interactive {
                    Spacer(minLength: 0)
                    Button { preview.dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close request preview")
                }
            }
            ScrollView {
                Text(question).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 280)
            if let outcome {
                switch outcome {
                case .loading: ProgressView("Revealing request\u{2026}").font(.footnote)
                case .revealed: Label("Revealed in Conversation", systemImage: "checkmark").font(.footnote)
                case .failed(let error):
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    }
                    .font(.footnote)
                }
            }
            if interactive {
                Button(revealTitle, action: reveal).disabled(isLoading).frame(minHeight: 44)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(RequestPreviewCoverage(interaction: interaction))
    }

    private func reveal() {
        let token = interaction.reveal(sequence: request.sequence)
        preview.begin(.init(sequence: request.sequence, text: request.text), token: token)
    }

    private func synchronize() {
        guard scenePhase == .active else { return }
        preview.update(interaction.revealProgress, requestSequence: request.sequence,
                       currentToken: interaction.revealRequestToken)
        if !allowsPresentation { preview.dismiss() }
    }
}

private struct RequestPreviewCoverage: UIViewControllerRepresentable {
    let interaction: ChannelInteraction

    func makeUIViewController(context: Context) -> Controller { Controller(interaction: interaction) }
    func updateUIViewController(_ controller: Controller, context: Context) {}
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.releaseCoverage()
    }

    final class Controller: UIViewController {
        private let interaction: ChannelInteraction
        private let token = UUID()

        init(interaction: ChannelInteraction) {
            self.interaction = interaction
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { return nil }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            interaction.requestPreviewDidAppear(token)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            releaseCoverage()
        }

        func releaseCoverage() { interaction.requestPreviewDidDisappear(token) }
    }
}

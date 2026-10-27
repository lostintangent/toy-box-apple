import ChannelClient
import ChannelKit
import AppKit
import Foundation
import Observation
import SwiftUI
import ToyBoxUI

extension TranscriptFind {
    var highlights: [Int: TranscriptFindHighlight] {
        guard isPresented else { return [:] }
        return Dictionary(uniqueKeysWithValues: matches.map {
            ($0.sequence, TranscriptFindHighlight(query: query, isCurrent: $0.sequence == selectedSequence))
        })
    }
}

struct TranscriptFindHighlight: Equatable {
    let query: String
    let isCurrent: Bool

    var shared: ToyBoxUI.TranscriptFindHighlight {
        .init(query: query, isCurrent: isCurrent, background: Color(nsColor: .findHighlightColor),
              foreground: Color(nsColor: .black))
    }

    func applying(to value: AttributedString, ranges: [Range<Int>]? = nil,
                  offset: Int = 0) -> AttributedString {
        shared.applying(to: value, ranges: ranges, offset: offset)
    }
}

struct TranscriptFindBar: View {
    @Bindable var find: TranscriptFind
    let channelName: String
    var focusRequest: UUID
    var navigate: (Int) -> Void
    var close: () -> Void
    var announce: @MainActor (String) -> Void
    @ViewState private var progressDelayElapsed = false
    @ViewState private var showsError = false

    var body: some View {
        HStack(spacing: 8) {
            TranscriptFindField(query: $find.query, focusRequest: focusRequest, navigate: navigate, close: close)
            .frame(height: 28)
            TranscriptFindStatusView(status: find.status(progressDelayElapsed: progressDelayElapsed),
                                     found: find.partialCountLabel, showsError: $showsError) {
                showsError = false
                find.retryHistory()
            }
            ControlGroup {
                Button("Previous Match", systemImage: "chevron.left") { navigate(-1) }
                    .help("Previous Match (Shift-Command-G)")
                Button("Next Match", systemImage: "chevron.right") { navigate(1) }
                    .help("Next Match (Command-G)")
            }
            .controlGroupStyle(.navigation)
            .disabled(find.matches.isEmpty)
            .accessibilityIdentifier("channel-find-navigation")
            Button("Done", action: close).frame(minHeight: 28)
            .help("Close Find")
            .accessibilityLabel("Close Find")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in \(channelName)")
        .onExitCommand(perform: close)
        .transcriptFindStatusUpdates(find, progressDelayElapsed: $progressDelayElapsed, announce: announce)
        .onChange(of: find.query) { showsError = false }
        .onChange(of: find.error == nil) { if find.error == nil { showsError = false } }
    }
}

/// One width for every nonempty query, so a spinner, count or Incomplete swap never moves the field.
struct TranscriptFindStatusView: View {
    static let width: CGFloat = 84
    let status: TranscriptFindStatus
    let found: String
    @Binding var showsError: Bool
    var retry: () -> Void

    var body: some View {
        content
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: Self.width, height: 28, alignment: .trailing)
    }

    @ViewBuilder private var content: some View {
        switch status {
        case .hidden, .blank:
            Color.clear.accessibilityHidden(true)
        case .progress:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Searching older messages")
        case .result(let result):
            Text(result)
                .lineLimit(1)
                .accessibilityLabel("Matching messages: \(result)")
        case .incomplete(let error):
            Button { showsError = true } label: {
                Label {
                    Text("Incomplete").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
                .frame(minHeight: 28)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Couldn't search older messages")
            .accessibilityLabel("Search incomplete")
            .accessibilityHint("Shows why older messages couldn't be searched, with Retry.")
            .popover(isPresented: $showsError, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't search older messages").font(.headline)
                    Text(error).foregroundStyle(.secondary)
                    Text(found).foregroundStyle(.secondary)
                    Button("Retry", action: retry)
                        .keyboardShortcut(.defaultAction)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260)
                .padding(14)
            }
        }
    }
}

private struct TranscriptFindField: NSViewRepresentable {
    @Binding var query: String
    let focusRequest: UUID
    var navigate: (Int) -> Void
    var close: () -> Void

    func makeNSView(context: Context) -> FindField {
        let field = FindField()
        field.placeholderString = "Search this channel"
        field.setAccessibilityIdentifier("channel-find-field")
        field.setAccessibilityLabel("Search this channel")
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.onAttach = { [weak coordinator = context.coordinator] in coordinator?.focus($0) }
        return field
    }

    func updateNSView(_ field: FindField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
        context.coordinator.focus(field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class FindField: NSSearchField {
        var onAttach: ((FindField) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onAttach?(self) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TranscriptFindField
        private var focusedRequest: UUID?
        init(_ parent: TranscriptFindField) { self.parent = parent }

        func focus(_ field: NSSearchField) {
            guard field.window != nil, focusedRequest != parent.focusRequest else { return }
            focusedRequest = parent.focusRequest
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }

        @objc func changed(_ field: NSSearchField) { parent.query = field.stringValue }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { changed(field) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.cancelOperation(_:)) {
                parent.close()
                return true
            }
            if command == #selector(NSResponder.insertNewline(_:))
                || command == #selector(NSResponder.insertLineBreak(_:)) {
                let previous = command == #selector(NSResponder.insertLineBreak(_:))
                    || NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                parent.navigate(previous ? -1 : 1)
                return true
            }
            return false
        }
    }
}

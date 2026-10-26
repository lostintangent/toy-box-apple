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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TranscriptFindField(query: $find.query, focusRequest: focusRequest, navigate: navigate, close: close)
                .frame(height: 28)
                Text(find.countLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("Matching messages: \(find.countLabel)")
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
            if let error = find.error {
                HStack {
                    Text("Couldn't search older messages").foregroundStyle(.secondary).help(error)
                    Button("Retry") { find.retryHistory() }.buttonStyle(.borderless)
                }
                .font(.caption)
            } else if find.isSearching {
                Text("Searching older messages...").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in \(channelName)")
        .onExitCommand(perform: close)
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

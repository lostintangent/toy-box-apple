import ChannelKit
import SwiftUI
import ToyBoxUI

extension TranscriptFindHighlight {
    /// UIKit has no public find color, so this uses the system yellow its own find bar draws. Other
    /// matches show the page through their lighter fill, so their text follows the appearance.
    static func phone(query: String, isCurrent: Bool) -> TranscriptFindHighlight {
        .init(query: query, isCurrent: isCurrent, background: Color(uiColor: .systemYellow),
              foreground: isCurrent ? .black : Color(uiColor: .label))
    }
}

extension TranscriptFind {
    /// The count stays provisional until every older page has been searched.
    var phoneCountLabel: String {
        guard isSearching || error != nil, !matches.isEmpty else { return countLabel }
        if let index = matches.firstIndex(where: { $0.sequence == selectedSequence }) {
            return "\(index + 1) of \(matches.count) so far"
        }
        return matches.count == 1 ? "1 match so far" : "\(matches.count) matches so far"
    }
}

/// Find sits under the navigation bar on the system background, like Safari's find bar: a search
/// field with its count inside, then Previous, Next and Done. Status rows only appear below it.
struct TranscriptFindAccessory: View {
    @Bindable var find: TranscriptFind
    let focusRequest: UUID
    var navigate: (Int) -> Void
    var close: () -> Void
    @FocusState private var isFocused: Bool
    @ViewState private var selection: TextSelection?
    @ViewState private var showsProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                field
                navigation
                done
            }
            status
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in Conversation")
        // A task runs once the bar is in the hierarchy, so the field can take focus.
        .task(id: focusRequest) {
            isFocused = true
            selection = TextSelection(range: find.query.startIndex..<find.query.endIndex)
        }
        .task(id: find.isSearching) {
            showsProgress = false
            guard find.isSearching else { return }
            try? await Task.sleep(for: .milliseconds(300))
            showsProgress = find.isSearching
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search this channel", text: $find.query, selection: $selection)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    navigate(1)
                    isFocused = true
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    navigate(-1)
                    return .handled
                }
                .accessibilityIdentifier("channel-find-field")
            count
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
    }

    private var count: some View {
        Text(find.phoneCountLabel)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(1)
            .accessibilityLabel("Matching messages: \(find.phoneCountLabel)")
            .accessibilityHidden(find.phoneCountLabel.isEmpty)
    }

    private var navigation: some View {
        ControlGroup {
            Button("Previous Match", systemImage: "chevron.up") { navigate(-1) }
                .frame(minWidth: 44, minHeight: 44)
            Button("Next Match", systemImage: "chevron.down") { navigate(1) }
                .frame(minWidth: 44, minHeight: 44)
        }
        .controlGroupStyle(.navigation)
        .labelStyle(.iconOnly)
        .fixedSize()
        .disabled(find.matches.isEmpty)
    }

    private var done: some View {
        Button("Done", action: close)
            .fontWeight(.semibold)
            .frame(minWidth: 44, minHeight: 44)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Find")
    }

    @ViewBuilder private var status: some View {
        if let error = find.error {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't search older messages")
                    Text(error).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Retry") { find.retryHistory() }
                    .frame(minWidth: 44, minHeight: 44)
            }
            .font(.footnote)
        } else if find.isSearching {
            HStack(spacing: 6) {
                if showsProgress { ProgressView().controlSize(.small) }
                Text("Searching older messages…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(minHeight: 28)
        }
    }
}

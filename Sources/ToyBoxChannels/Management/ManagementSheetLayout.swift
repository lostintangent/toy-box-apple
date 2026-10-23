import SwiftUI

/// The one sheet language for New Channel, Edit Channel, Add Agent and Edit Member: a 40-point
/// identity mark over a grouped form, with notices and trailing buttons below it.
struct ManagementSheetLayout<Mark: View, Fields: View, Notices: View, Buttons: View>: View {
    static var width: CGFloat { 480 }

    let title: String
    let subtitle: String
    @ViewBuilder let mark: Mark
    @ViewBuilder let fields: Fields
    @ViewBuilder let notices: Notices
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                mark
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 2)
            ManagementFittedForm { fields }
            VStack(alignment: .leading, spacing: 10) {
                notices
                HStack { buttons }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .frame(width: Self.width)
    }
}

/// A grouped form as tall as its rows, so the sheet fits it with no empty band. It scrolls only
/// once the sheet would outgrow its window.
private struct ManagementFittedForm<Content: View>: View {
    @ViewBuilder let content: Content
    @ViewState private var contentHeight: CGFloat?

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                contentHeight = height
            }
            .frame(idealHeight: contentHeight)
    }
}

/// A section footer: help in 11-point secondary, or a real violation behind a red symbol.
struct ManagementFooter: View {
    var help: [String] = []
    var violation: String?

    var body: some View {
        Group {
            if let violation {
                Label {
                    Text(violation)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
            } else if !help.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(help, id: \.self) { Text($0) }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A multi-line field whose label sits above it, so its text shares the label's leading edge and
/// the single-line fields' chrome. Return submits, and Option-Return inserts a line break.
struct ManagementLongTextField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let lines: ClosedRange<Int>
    var violation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).accessibilityHidden(true)
            TextField(title, text: $text, prompt: Text(prompt), axis: .vertical)
                .labelsHidden()
                .lineLimit(lines)
                .accessibilityHint(violation ?? "")
        }
    }
}

/// The sidebar's cyan channel mark at sheet size.
struct ManagementChannelMark: View {
    var body: some View {
        Image(systemName: "number")
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(ChannelSidebarRow.cyan.gradient))
    }
}

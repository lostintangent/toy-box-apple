import SwiftUI

public struct ManagementFooter: View {
    let help: [String]
    let violation: String?

    public init(help: [String] = [], violation: String? = nil) {
        self.help = help
        self.violation = violation
    }

    public var body: some View {
        Group {
            if let violation {
                Label {
                    Text(violation)
                        #if os(iOS)
                        .foregroundStyle(Color.primary)
                        #endif
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
            } else if !help.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(help, id: \.self) { Text($0) }
                }
            }
        }
        #if os(iOS)
        .font(.footnote)
        .foregroundStyle(ChannelInk.secondary)
        #else
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        #endif
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

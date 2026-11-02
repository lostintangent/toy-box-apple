import Foundation

/// A request's suggested answers as notification actions. Every surface derives the category, the
/// action titles and the sent label from the same validated labels.
public struct SuggestedReplies: Equatable, Sendable {
    /// The trimmed labels a request offers, or none when the list isn't 2 to 4 usable labels.
    public let labels: [String]

    public init(_ replies: [String]?) {
        let trimmed = (replies ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if (2...4).contains(trimmed.count), trimmed.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 80 }) {
            labels = trimmed
        } else {
            labels = []
        }
    }

    public static func actionIdentifier(at index: Int) -> String {
        "\(actionPrefix)\(index)"
    }

    /// The label a tapped choice sends, or nil when the action isn't one of these labels.
    public func label(forAction action: String) -> String? {
        guard action.hasPrefix(Self.actionPrefix),
              let index = Int(action.dropFirst(Self.actionPrefix.count)),
              Self.actionIdentifier(at: index) == action else { return nil }
        return labels.indices.contains(index) ? labels[index] : nil
    }

    private static let actionPrefix = "reply-choice."
}

import Foundation

/// A request's suggested answers as notification actions. Every surface derives the category, the
/// action titles and the sent label from the same validated labels.
public enum SuggestedReplies {
    public static let actionPrefix = "reply-choice."

    public static func actionIdentifier(_ index: Int) -> String {
        "\(actionPrefix)\(index)"
    }

    /// The trimmed labels a request offers, or none when the list isn't 2 to 4 usable labels.
    public static func labels(_ replies: [String]?) -> [String] {
        guard let replies else { return [] }
        let labels = replies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (2...4).contains(labels.count),
              labels.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 80 }) else { return [] }
        return labels
    }

    /// The label a tapped choice sends, read from a push's raw `replies`.
    public static func label(forAction action: String, replies: [String]?) -> String? {
        guard action.hasPrefix(actionPrefix), let index = Int(action.dropFirst(actionPrefix.count)),
              actionIdentifier(index) == action else { return nil }
        let labels = labels(replies)
        return labels.indices.contains(index) ? labels[index] : nil
    }
}

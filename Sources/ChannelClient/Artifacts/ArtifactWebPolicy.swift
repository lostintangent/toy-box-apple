import CryptoKit
import Foundation

public enum ArtifactWebError: LocalizedError, Equatable, Sendable {
    case invalidServer, missingRules, blockedNavigation, browserUnavailable, rootDocumentUnavailable, rootNavigationUnavailable
    case invalidReadingState

    public var errorDescription: String? {
        switch self {
        case .invalidServer: "The artifact's server address is unavailable."
        case .missingRules: "The artifact's network isolation could not be installed."
        case .blockedNavigation: "This document tried to open an unsupported address."
        case .browserUnavailable: "The link could not be opened in your default browser."
        case .rootDocumentUnavailable: "The document's sandboxed address could not be created."
        case .rootNavigationUnavailable: "This document cannot replace its sandboxed page. Forms that navigate and other page navigation are not supported in the artifact viewer."
        case .invalidReadingState: "The document's reading position could not be saved."
        }
    }
}

public enum ArtifactWebPolicy {
    public enum NavigationKind: Sendable { case link, form, other }
    public enum Decision: Equatable, Sendable {
        case allow
        case fragment(String)
        case external(URL)
        case block(ArtifactWebError)
    }
    public enum PopupDecision: Equatable, Sendable {
        case external(URL)
        case block(ArtifactWebError)
    }

    public static let scheme = "toybox-artifact"
    public static let allowsUnsolicitedPopups = false
    public static let htmlPermissions = [
        "allow-downloads", "allow-forms", "allow-modals", "allow-popups",
        "allow-scripts", "allow-top-navigation-by-user-activation",
    ]
    public static let responseHeaders = [
        "Content-Type": "text/html; charset=utf-8",
        "Content-Security-Policy": "sandbox " + htmlPermissions.joined(separator: " "),
        "Referrer-Policy": "no-referrer",
    ]

    public static func rootDocumentURL(_ html: String, identity: URL) throws -> URL {
        let digest = SHA256.hash(data: Data((identity.absoluteString + "\n" + html).utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "\(scheme)://document/\(digest)") else {
            throw ArtifactWebError.rootDocumentUnavailable
        }
        return url
    }

    public static func contains(_ candidate: URL, root: URL?) -> Bool {
        guard var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return root != nil && components.url == root
    }

    public static func navigation(_ url: URL?, kind: NavigationKind, mainFrame: Bool?,
                                  root: URL?, directory: URL?, resource: URL?) -> Decision {
        if kind == .form { return .block(.rootNavigationUnavailable) }
        guard let url else { return .block(.blockedNavigation) }
        let scheme = url.scheme?.lowercased() ?? ""
        if mainFrame == true {
            if contains(url, root: root) { return .allow }
            if kind != .link || !["http", "https"].contains(scheme) { return .block(.rootNavigationUnavailable) }
        }
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else { return .block(.blockedNavigation) }
        if kind == .link, ["http", "https"].contains(scheme) {
            if let fragment = url.fragment, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                parts.fragment = nil
                if parts.url == directory || parts.url == resource { return .fragment(fragment) }
            }
            return .external(url)
        }
        if url.scheme == "about" || mainFrame == false || mainFrame == nil { return .allow }
        return .block(.blockedNavigation)
    }

    /// WebKit must first enforce `allowsUnsolicitedPopups` on the configuration.
    public static func popup(_ url: URL?, kind: NavigationKind) -> PopupDecision {
        if kind == .form { return .block(.rootNavigationUnavailable) }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .block(.blockedNavigation)
        }
        return .external(url)
    }

    public static func document(_ content: String, directory: URL) -> String {
        let base = "<base data-toybox-file-base href=\"\(attribute(directory.absoluteString))\">"
        if let head = content.range(of: #"<head(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(content[..<head.upperBound]) + base + content[head.upperBound...]
        } else if let html = content.range(of: #"<html(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(content[..<html.upperBound]) + "<head>\(base)</head>" + content[html.upperBound...]
        } else {
            return "<head>\(base)</head>" + content
        }
    }

    public static func blockingRules(server: URL) throws -> String {
        guard var origin = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            throw ArtifactWebError.invalidServer
        }
        let prefix = origin.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        guard let address = origin.url?.absoluteString else { throw ArtifactWebError.invalidServer }
        let escapedOrigin = NSRegularExpression.escapedPattern(for: address.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let filePath = (prefix.isEmpty ? "" : "/\(prefix)") + "/api/serve/"
        let files = escapedOrigin + NSRegularExpression.escapedPattern(for: filePath)
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": "^\(escapedOrigin)/"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://[^/]+/.*api/v1"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?://[^/]+/.*api/v1"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^\(files)"], "action": ["type": "ignore-previous-rules"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        guard let encoded = String(data: data, encoding: .utf8) else { throw ArtifactWebError.invalidServer }
        return encoded
    }

    private static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

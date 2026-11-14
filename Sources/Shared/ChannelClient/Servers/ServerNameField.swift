import ChannelClient
import Foundation
import Observation

/// A saved server's Name in Settings on both apps: what's typed until the server takes it, and why
/// the last rename didn't. See Naming a server in docs/spec.md.
@MainActor @Observable
public final class ServerNameField {
    public struct Failure: Equatable, Sendable {
        /// "Couldn't rename Mac mini.", by the name the server had.
        public let words: String
        public let reason: String
    }

    public let catalog: ChannelCatalogStore
    /// Why the last rename failed, until the next one or until the field holds the server's name.
    public private(set) var failure: Failure?
    private var typed: String?
    private var renaming: String?

    public init(_ catalog: ChannelCatalogStore) {
        self.catalog = catalog
    }

    /// What the field shows: what's typed, or else the server's name, which a read keeps current.
    /// While the server isn't connected it shows the server's last name.
    public var text: String {
        get { isEditable ? typed ?? catalog.name : catalog.name }
        set { typed = newValue }
    }

    public var isEditable: Bool { catalog.phase == .connected }

    /// Renames the server to what's typed, if that changed its name, on Return or when the field loses
    /// focus. A rename that fails keeps what's typed and says why.
    public func commit() async {
        guard isEditable, let typed, typed != renaming else { return }
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines) != catalog.name else {
            self.typed = nil
            failure = nil
            return
        }
        let name = catalog.name
        renaming = typed
        defer { if renaming == typed { renaming = nil } }
        do {
            try await catalog.rename(to: typed)
            failure = nil
            if self.typed == typed { self.typed = nil }
        } catch {
            failure = Failure(words: "Couldn't rename \(name).", reason: error.localizedDescription)
        }
    }
}

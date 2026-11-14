import Foundation

extension URL {
    /// Where drafts and the outbox are saved. The Mac app isn't sandboxed, so a copy that runs beside
    /// the installed app names its own folder in Info.plist instead of sharing this one.
    static func savedWriting(in bundle: Bundle = .main) -> URL {
        let folder = bundle.object(forInfoDictionaryKey: "ToyBoxDataFolder") as? String ?? "ToyBoxDesktop"
        return .applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory)
    }
}

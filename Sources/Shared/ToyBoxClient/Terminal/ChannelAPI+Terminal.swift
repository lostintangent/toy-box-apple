import Foundation

extension ChannelAPI {
    /// The ID that names this device's shell on the server, made and saved the first time, so
    /// opening the terminal again resumes the same shell while the server keeps it.
    public func terminalClientID(in defaults: UserDefaults) -> String {
        let key = "terminalClientID \(baseURL.absoluteString)"
        if let id = defaults.string(forKey: key) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}

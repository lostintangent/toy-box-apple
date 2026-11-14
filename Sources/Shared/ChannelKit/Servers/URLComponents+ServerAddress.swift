import Foundation

extension URLComponents {
    /// A server's address as someone typed it, trimmed. One without a scheme gets `https://`, so a
    /// bare host like `machine.tail1234.ts.net` or `my-server:3100` is HTTPS, and HTTP needs
    /// `http://` typed, localhost included. Read alone, `my-server:3100` would be a scheme.
    public init?(serverAddress: String) {
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(string: address.contains("://") ? address : "https://" + address)
    }
}

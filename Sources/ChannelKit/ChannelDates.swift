import Foundation

public enum ChannelDates {
    public static func date(_ value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }
}

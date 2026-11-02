import ChannelKit
import Foundation

/// Routine rows re-render with their inspector, so each schedule is parsed once per locale
/// rather than on every body.
@MainActor
package enum RoutineScheduleSummary {
    private static var summaries: [String: String] = [:]
    private static var localeObserver: (any NSObjectProtocol)?

    package static func text(for schedule: String) -> String {
        if let summary = summaries[schedule] { return summary }
        if localeObserver == nil {
            localeObserver = NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { summaries.removeAll() }
            }
        }
        if summaries.count >= 256 { summaries.removeAll() }
        let summary = (try? RoutineSchedule(schedule).summary()) ?? schedule
        summaries[schedule] = summary
        return summary
    }
}

import ChannelKit
import Foundation
import OSLog

enum WidgetSnapshotReader {
    private static let logger = Logger(subsystem: "dev.toybox.desktop.widget", category: "Snapshot")

    static func load() -> NeedsYouSnapshot? {
        guard Bundle.main.object(forInfoDictionaryKey: NeedsYouSnapshot.groupInfoKey) as? String == NeedsYouSnapshot.appGroup,
              let directory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: NeedsYouSnapshot.appGroup
              ) else {
            logger.error("The widget has no accessible app group.")
            return nil
        }
        do {
            let snapshot = try JSONDecoder().decode(NeedsYouSnapshot.self,
                from: Data(contentsOf: directory.appendingPathComponent(NeedsYouSnapshot.fileName)))
            guard snapshot.version == 1 else {
                logger.error("The widget snapshot version is unsupported.")
                return nil
            }
            return snapshot
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            logger.error("Could not read the widget snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

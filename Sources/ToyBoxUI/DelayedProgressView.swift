import SwiftUI

private typealias ViewState = SwiftUI.State

/// A native progress indicator that waits 300 ms before it appears, so quick work never flashes
/// one. Show it while work is pending. It holds its place from the start, so nothing moves when it
/// appears. Pass `since` when the work began before this view did, such as in a rebuilt row.
public struct DelayedProgressView: View {
    public static let delay = Duration.milliseconds(300)

    private let title: LocalizedStringKey?
    private let since: ContinuousClock.Instant?
    @ViewState private var isShown = false

    public init(since: ContinuousClock.Instant? = nil) {
        title = nil
        self.since = since
    }

    public init(_ title: LocalizedStringKey, since: ContinuousClock.Instant? = nil) {
        self.title = title
        self.since = since
    }

    public var body: some View {
        Group {
            if let title { ProgressView(title) } else { ProgressView() }
        }
        .opacity(isShown ? 1 : 0)
        .accessibilityHidden(!isShown)
        .task(id: since) {
            isShown = false
            let remaining = Self.delay - (since ?? .now).duration(to: .now)
            if remaining > .zero {
                do { try await Task.sleep(for: remaining) } catch { return }
            }
            isShown = true
        }
    }
}

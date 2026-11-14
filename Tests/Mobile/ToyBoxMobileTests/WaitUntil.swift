import Observation
import Testing
#if canImport(AppKit)
import AppKit
typealias HostedView = NSView
#else
import UIKit
typealias HostedView = UIView
#endif

/// Waits until the condition holds. It checks again whenever observable state the condition read
/// changes, and on every frame for a fact with no signal, like a hosted view's layout or a native
/// control's state. Each check first lays out the view, and on the Mac draws its window. The deadline
/// allows for a full run on a busy machine, so only a failure ever reaches it.
///
/// Each test target that hosts views has this same file. Keep the copies identical.
@MainActor
func waitUntil(_ description: @autoclosure () -> String = "the expected state", in view: HostedView? = nil,
               sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    let (checks, check) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let frames = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            check.yield()
        }
    }
    defer {
        frames.cancel()
        check.finish()
    }
    var next = checks.makeAsyncIterator()
    while true {
        #if canImport(AppKit)
        view?.layoutSubtreeIfNeeded()
        view?.window?.displayIfNeeded()
        #else
        view?.layoutIfNeeded()
        #endif
        var result: Result<Bool, any Error> = .success(false)
        withObservationTracking { result = Result { try condition() } } onChange: { check.yield() }
        if try result.get() { return }
        try #require(ContinuousClock.now < deadline, "Timed out waiting until \(description())",
                     sourceLocation: sourceLocation)
        try Task.checkCancellation()
        _ = await next.next()
    }
}

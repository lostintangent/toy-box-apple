import ChannelClient
import Foundation
import Testing

@MainActor
struct ConnectGraceTests {
    @Test func aBriefConnectDoesNotFlashWhySendIsOff() async {
        let grace = ConnectGrace()
        grace.duration = .milliseconds(100)
        let first = NSObject()
        let second = NSObject()
        let shown = ObjectIdentifier(first)
        #expect(grace.explains(.stale(message: "Offline", retryAt: .now), for: shown))
        #expect(grace.explains(.deleted, for: shown))
        #expect(!grace.explains(.live, for: shown))
        #expect(!grace.explains(.idle, for: shown), "A switch shows the channel before it connects")
        #expect(!grace.explains(.connecting, for: shown), "A connect starts without the explanation")

        let finished = Task { await grace.watch(.connecting, for: shown) }
        finished.cancel()
        await finished.value
        #expect(!grace.explains(.connecting, for: shown), "A connect that finishes in time never explains")

        let started = ContinuousClock.now
        await grace.watch(.connecting, for: shown)
        #expect(ContinuousClock.now - started >= .milliseconds(100))
        #expect(grace.explains(.connecting, for: shown), "A slow connect explains")
        #expect(!grace.explains(.connecting, for: ObjectIdentifier(second)),
                "Another channel's slow connect doesn't carry over")

        await grace.watch(.live, for: shown)
        #expect(!grace.explains(.connecting, for: shown), "The next connect starts quiet again")
        await grace.watch(.idle, for: shown)
        #expect(grace.explains(.idle, for: shown), "A channel that never starts connecting explains")
        await grace.watch(.connecting, for: shown)
        grace.reset()
        #expect(!grace.explains(.connecting, for: shown), "A switch starts quiet before its first frame")
    }
}

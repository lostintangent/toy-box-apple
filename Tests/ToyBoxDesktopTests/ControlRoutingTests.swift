import Foundation
import Testing
import ToyBoxControlIntents
@testable import ToyBoxDesktop

@MainActor
@Suite struct ControlRoutingTests {
    @Test func controlRoutesMarkTheLaunchBeforeOpeningExactlyTheirTarget() throws {
        let original = AppDelegate.receivedOpenEvent
        defer { AppDelegate.receivedOpenEvent = original }
        var opened: [URL] = []
        let router = ToyBoxControlsContext.makeRouter { url in
            #expect(AppDelegate.receivedOpenEvent)
            #expect(!AppLoginLaunch.shouldOpenStartupWindow(
                login: false, backgroundIntent: false,
                receivedContent: AppDelegate.receivedOpenEvent, hasMainWindow: false))
            opened.append(url)
            return true
        }
        for target in [ToyBoxControlDestination.quickSend, .needsYou] {
            AppDelegate.receivedOpenEvent = false
            try router.open(target.url)
        }
        #expect(opened == [ToyBoxControlDestination.quickSend.url, ToyBoxControlDestination.needsYou.url])
    }

    @Test(arguments: [false, true])
    func unavailableAndFailedRoutesStayMarkedAndPropagateTheirErrors(throwFromRoute: Bool) {
        let original = AppDelegate.receivedOpenEvent
        defer { AppDelegate.receivedOpenEvent = original }
        AppDelegate.receivedOpenEvent = false
        let router = ToyBoxControlsContext.makeRouter { _ in
            #expect(AppDelegate.receivedOpenEvent)
            if throwFromRoute { throw CocoaError(.fileReadNoPermission) }
            return false
        }
        #expect(throws: (any Error).self) {
            try router.open(ToyBoxControlDestination.quickSend.url)
        }
        #expect(AppDelegate.receivedOpenEvent)
    }
}

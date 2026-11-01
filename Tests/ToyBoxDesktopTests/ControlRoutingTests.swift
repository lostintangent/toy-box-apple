import Foundation
import Testing
import ToyBoxControlIntents
@testable import ToyBoxDesktop

@MainActor
@Suite struct ControlRoutingTests {
    @Test func controlRoutesMarkTheLaunchBeforeOpeningExactlyTheirTarget() throws {
        let delegate = AppDelegate()
        var opened: [URL] = []
        let router = ToyBoxControlsContext.makeRouter(delegate: delegate) { url in
            #expect(delegate.receivedOpenEvent)
            #expect(!AppLoginLaunch.shouldOpenStartupWindow(
                login: false, backgroundIntent: false,
                receivedContent: delegate.receivedOpenEvent, hasMainWindow: false))
            opened.append(url)
            return true
        }
        for target in [ToyBoxControlDestination.quickSend, .needsYou] {
            delegate.receivedOpenEvent = false
            try router.open(target.url)
        }
        #expect(opened == [ToyBoxControlDestination.quickSend.url, ToyBoxControlDestination.needsYou.url])
    }

    @Test(arguments: [false, true])
    func unavailableAndFailedRoutesStayMarkedAndPropagateTheirErrors(throwFromRoute: Bool) {
        let delegate = AppDelegate()
        let router = ToyBoxControlsContext.makeRouter(delegate: delegate) { _ in
            #expect(delegate.receivedOpenEvent)
            if throwFromRoute { throw CocoaError(.fileReadNoPermission) }
            return false
        }
        #expect(throws: (any Error).self) {
            try router.open(ToyBoxControlDestination.quickSend.url)
        }
        #expect(delegate.receivedOpenEvent)
    }
}

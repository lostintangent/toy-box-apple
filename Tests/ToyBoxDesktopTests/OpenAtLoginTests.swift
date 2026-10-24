import AppKit
import ServiceManagement
import Testing
@testable import ToyBoxDesktop

@MainActor
@Suite("Open at Login")
struct OpenAtLoginTests {
    @Test func openingSettingsNeverRegistersAnUnregisteredApp() {
        let service = LoginItemServiceFake()
        let controller = OpenAtLogin(isAvailable: true, service: service.service)
        #expect(controller.status == .notRegistered)
        #expect(!controller.isEnabled)
        #expect(controller.statusMessage == nil)
        #expect(service.actions == ["status"])
    }

    @Test(arguments: [
        SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound,
    ])
    func theToggleReportsOnlyActuallyEnabledServices(_ status: SMAppService.Status) {
        let service = LoginItemServiceFake(status: status)
        let controller = OpenAtLogin(isAvailable: true, service: service.service)
        #expect(controller.isEnabled == (status == .enabled))
        #expect(controller.requiresApproval == (status == .requiresApproval))
        #expect((controller.statusMessage != nil) == (status == .requiresApproval || status == .notFound))
    }

    @Test func explicitEnableAndDisableUseTheServiceAndReadBackItsState() async {
        let service = LoginItemServiceFake()
        let controller = OpenAtLogin(isAvailable: true, service: service.service)
        await controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(controller.error == nil)
        await controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(controller.status == .notRegistered)
        #expect(controller.error == nil)
        #expect(service.actions.filter { $0 != "status" } == ["register", "unregister"])
    }

    @Test func approvalRequiredNeverBecomesAnOptimisticCheckmark() async {
        let service = LoginItemServiceFake()
        service.registrationStatus = .requiresApproval
        let controller = OpenAtLogin(isAvailable: true, service: service.service)
        await controller.setEnabled(true)
        #expect(!controller.isEnabled)
        #expect(controller.requiresApproval)
        #expect(controller.statusMessage == "Allow Toy Box in System Settings to open at login.")
        await controller.setEnabled(true)
        #expect(!controller.isEnabled)
        #expect(service.actions.filter { $0 != "status" } == ["register", "settings"])
        await controller.setEnabled(false)
        #expect(controller.status == .notRegistered)
    }

    @Test func failedRegistrationReportsItsErrorAndKeepsTheActualState() async {
        let service = LoginItemServiceFake()
        service.registrationError = LoginItemFailure()
        let controller = OpenAtLogin(isAvailable: true, service: service.service)
        await controller.setEnabled(true)
        #expect(!controller.isEnabled)
        #expect(controller.error == "Couldn't enable Open at Login: The service rejected this change.")
        #expect(!controller.isUpdating)
        service.registrationError = nil
        await controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(controller.error == nil)
    }

    @Test func failedUnregistrationDoesNotPretendTheAppIsDisabled() async {
        let service = LoginItemServiceFake(status: .enabled)
        service.unregistrationError = LoginItemFailure()
        let controller = OpenAtLogin(isAvailable: true, service: service.service)
        await controller.setEnabled(false)
        #expect(controller.isEnabled)
        #expect(controller.error == "Couldn't disable Open at Login: The service rejected this change.")
        #expect(!controller.isUpdating)
    }

    @Test func evenAnErrorReadsBackARegistrationThatReachedTheSystem() async {
        var status = SMAppService.Status.notRegistered
        let service = OpenAtLogin.Service(
            status: { status },
            register: { status = .requiresApproval; throw LoginItemFailure() },
            unregister: { status = .notRegistered },
            openSettings: {}
        )
        let controller = OpenAtLogin(isAvailable: true, service: service)
        await controller.setEnabled(true)
        #expect(controller.status == .requiresApproval)
        #expect(!controller.isEnabled)
        #expect(controller.error != nil)
    }

    @Test func externalChangesAreReadBackBeforeAnyMutation() async {
        let service = LoginItemServiceFake()
        let controller = OpenAtLogin(isAvailable: true, service: service.service)
        service.status = .enabled
        await controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(service.actions.allSatisfy { $0 == "status" })
        service.status = .requiresApproval
        controller.refresh()
        #expect(!controller.isEnabled)
        #expect(controller.requiresApproval)
    }

    @Test func aPendingUnregistrationCannotBeOverlappedByAnotherChange() async {
        let service = LoginItemServiceFake(status: .enabled)
        var continuation: CheckedContinuation<Void, Never>?
        service.beforeUnregister = {
            await withCheckedContinuation { continuation = $0 }
        }
        let controller = OpenAtLogin(isAvailable: true, service: service.service)
        let pending = Task { await controller.setEnabled(false) }
        while continuation == nil { await Task.yield() }
        #expect(controller.isUpdating)
        #expect(controller.isEnabled)
        await controller.setEnabled(false)
        await controller.setEnabled(true)
        #expect(service.actions.filter { $0 != "status" } == ["unregister"])
        continuation?.resume()
        await pending.value
        #expect(!controller.isUpdating)
        #expect(!controller.isEnabled)
    }

    @Test func unavailableCopiesDoNotEvenQueryTheLiveService() async {
        let service = LoginItemServiceFake(status: .enabled)
        let controller = OpenAtLogin(isAvailable: false, service: service.service)
        controller.refresh()
        controller.openSettings()
        await controller.setEnabled(true)
        await controller.setEnabled(false)
        #expect(!controller.isAvailable)
        #expect(!controller.isEnabled)
        #expect(controller.statusMessage != nil)
        #expect(service.actions.isEmpty)
    }

    @Test func mutationsAreLimitedToAnOrdinaryProductionLaunch() throws {
        #expect(OpenAtLogin.isAllowed(.init(), bundleID: "dev.toybox.desktop", environment: [:]))
        for identifier in [nil, "", "dev.toybox.desktop.test", "dev.toybox.desktop.benchmark",
                           "dev.toybox.channels.mac", "dev.toybox.desktop.other"] {
            #expect(!OpenAtLogin.isAllowed(.init(), bundleID: identifier, environment: [:]))
        }
        let arguments = [
            ["--server", "http://127.0.0.1:3210"],
            ["--channel", "studio-demo", "--snapshot", "/tmp/login-test.png"],
            ["--channel", "studio-demo", "--benchmark", "launch"],
            ["--channel", "studio-demo", "--benchmark-resize", "width"],
            ["--validate-quick-send", "hold"],
        ]
        for arguments in arguments {
            let options = try LaunchOptions.parse(arguments)
            #expect(!OpenAtLogin.isAllowed(options, bundleID: "dev.toybox.desktop", environment: [:]))
        }
        #expect(!OpenAtLogin.isAllowed(.init(), bundleID: "dev.toybox.desktop",
                                      environment: ["TOY_BOX_SERVER_URL": "http://127.0.0.1:3210"]))
    }

    @Test func loginDetectionRequiresTheExplicitOpenApplicationEventProperty() {
        #expect(!AppLoginLaunch.isLoginEvent(nil))
        #expect(!AppLoginLaunch.isLoginEvent(event()))
        #expect(!AppLoginLaunch.isLoginEvent(event(property: OSType(keyAELaunchedAsServiceItem))))
        #expect(!AppLoginLaunch.isLoginEvent(event(id: AEEventID(kAEReopenApplication),
                                                 property: OSType(keyAELaunchedAsLogInItem))))
        #expect(!AppLoginLaunch.isLoginEvent(event(eventClass: 0, property: OSType(keyAELaunchedAsLogInItem))))
        #expect(AppLoginLaunch.isLoginEvent(event(property: OSType(keyAELaunchedAsLogInItem))))
    }

    @Test(arguments: [false, true], [false, true])
    func quietLoginKeepsTheDockAndIsSeparateFromAccessoryIntents(login: Bool, backgroundIntent: Bool) {
        #expect(AppLoginLaunch.suppressesStartupWindow(login: login, backgroundIntent: backgroundIntent)
                == (login || backgroundIntent))
        #expect(AppLoginLaunch.activationPolicy(login: login, backgroundIntent: backgroundIntent)
                == (backgroundIntent && !login ? .accessory : .regular))
    }

    @Test func restoredWindowsAndOpenEventsNeverGetAnExtraEmptyWindow() {
        #expect(AppLoginLaunch.shouldOpenStartupWindow(
            login: false, backgroundIntent: false, receivedContent: false, hasMainWindow: false))
        #expect(!AppLoginLaunch.shouldOpenStartupWindow(
            login: false, backgroundIntent: false, receivedContent: true, hasMainWindow: false))
        #expect(!AppLoginLaunch.shouldOpenStartupWindow(
            login: false, backgroundIntent: false, receivedContent: false, hasMainWindow: true))
        #expect(!AppLoginLaunch.shouldOpenStartupWindow(
            login: true, backgroundIntent: false, receivedContent: false, hasMainWindow: false))
        #expect(!AppLoginLaunch.shouldOpenStartupWindow(
            login: false, backgroundIntent: true, receivedContent: false, hasMainWindow: false))
    }

    @Test func theActualURLDelegateMarksAHandledLaunchBeforeOpeningItsOnlyTarget() throws {
        let originalHandler = AppDelegate.widgetURLHandler
        let originalReceivedOpenEvent = AppDelegate.receivedOpenEvent
        defer {
            AppDelegate.widgetURLHandler = originalHandler
            AppDelegate.receivedOpenEvent = originalReceivedOpenEvent
        }
        AppDelegate.receivedOpenEvent = false
        var opened: [URL] = []
        var wasMarkedBeforeOpening = false
        AppDelegate.widgetURLHandler = { url in
            wasMarkedBeforeOpening = AppDelegate.receivedOpenEvent
            opened.append(url)
            return true
        }
        let url = try #require(URL(string: "toybox-desktop://quick-send"))
        AppDelegate().application(NSApplication.shared, open: [url])
        #expect(wasMarkedBeforeOpening)
        #expect(opened == [url])
        #expect(!AppLoginLaunch.shouldOpenStartupWindow(
            login: false, backgroundIntent: false,
            receivedContent: AppDelegate.receivedOpenEvent, hasMainWindow: false))
    }

    private func event(eventClass: AEEventClass = AEEventClass(kCoreEventClass),
                       id: AEEventID = AEEventID(kAEOpenApplication),
                       property: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: eventClass, eventID: id, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let property {
            event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }
}

@MainActor
private final class LoginItemServiceFake {
    var status: SMAppService.Status
    var registrationStatus: SMAppService.Status = .enabled
    var registrationError: (any Error)?
    var unregistrationError: (any Error)?
    var beforeUnregister: (() async -> Void)?
    var actions: [String] = []

    init(status: SMAppService.Status = .notRegistered) { self.status = status }

    var service: OpenAtLogin.Service {
        .init(
            status: { self.actions.append("status"); return self.status },
            register: {
                self.actions.append("register")
                if let error = self.registrationError { throw error }
                self.status = self.registrationStatus
            },
            unregister: {
                self.actions.append("unregister")
                await self.beforeUnregister?()
                if let error = self.unregistrationError { throw error }
                self.status = .notRegistered
            },
            openSettings: { self.actions.append("settings") }
        )
    }
}

private struct LoginItemFailure: LocalizedError {
    var errorDescription: String? { "The service rejected this change." }
}

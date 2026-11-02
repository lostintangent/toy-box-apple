import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class OpenAtLogin {
    @MainActor struct Service {
        var status: () -> SMAppService.Status
        var register: () throws -> Void
        var unregister: () async throws -> Void
        var openSettings: () -> Void

        static let mainApp = Service(
            status: { SMAppService.mainApp.status },
            register: { try SMAppService.mainApp.register() },
            unregister: { try await SMAppService.mainApp.unregister() },
            openSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
    }

    let isAvailable: Bool
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var isUpdating = false
    private(set) var error: String?
    @ObservationIgnored private let service: Service

    init(isAvailable: Bool, service: Service = .mainApp) {
        self.isAvailable = isAvailable
        self.service = service
        refresh()
    }

    static func isAllowed(_ options: LaunchOptions, bundleID: String?,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        bundleID == "dev.toybox.desktop" && options.allowsUserIntegrations(environment: environment)
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    var statusMessage: String? {
        guard isAvailable else { return "Open at Login is unavailable in test and validation builds." }
        switch status {
        case .enabled, .notRegistered: return nil
        case .requiresApproval: return "Allow Toy Box in System Settings to open at login."
        case .notFound: return "Login Items couldn't find this copy of Toy Box. Move it to Applications and try again."
        @unknown default: return "Login Items reported an unknown status. Review it in System Settings."
        }
    }

    func refresh() {
        guard isAvailable else { return }
        status = service.status()
    }

    func setEnabled(_ enabled: Bool) async {
        guard isAvailable, !isUpdating else { return }
        refresh()
        guard enabled != isEnabled || requiresApproval else { return }
        isUpdating = true
        error = nil
        defer {
            refresh()
            isUpdating = false
        }
        do {
            if enabled {
                if requiresApproval { service.openSettings() }
                else { try service.register() }
            } else {
                try await service.unregister()
            }
        } catch {
            self.error = "Couldn't \(enabled ? "enable" : "disable") Open at Login: \(error.localizedDescription)"
        }
    }

    func openSettings() {
        guard isAvailable else { return }
        service.openSettings()
    }
}

enum AppLoginLaunch {
    static func isLoginEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventClass == AEEventClass(kCoreEventClass)
            && event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == OSType(keyAELaunchedAsLogInItem)
    }

    static func suppressesStartupWindow(login: Bool, backgroundIntent: Bool) -> Bool {
        login || backgroundIntent
    }

    static func shouldOpenStartupWindow(login: Bool, backgroundIntent: Bool,
                                        receivedContent: Bool, hasMainWindow: Bool) -> Bool {
        !suppressesStartupWindow(login: login, backgroundIntent: backgroundIntent)
            && !receivedContent && !hasMainWindow
    }

    static func activationPolicy(login: Bool, backgroundIntent: Bool) -> NSApplication.ActivationPolicy {
        backgroundIntent && !login ? .accessory : .regular
    }
}

import AppKit
import ToyBoxClient
import Foundation
import Observation
import ScreenCaptureKit
import SwiftUI

#if DEBUG
/// Poses one window in a requested state and captures it for `bun run snapshot`. Only debug builds
/// have it, so the shipped app carries none of the harness.
@MainActor @Observable
final class WindowSnapshot {
    let options: LaunchOptions
    /// The state the window poses, asked for once its channel is live.
    private(set) var requestedState: String?
    private(set) var isStateReady = false
    private(set) var stateError: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var channel: ChannelStore?

    init(options: LaunchOptions) {
        self.options = options
        startDeadline(.seconds(35))
    }

    func markStateReady(_ name: String) {
        guard name == requestedState else { return }
        isStateReady = true
    }

    func failState(_ name: String, message: String) {
        guard name == requestedState else { return }
        stateError = message
    }

    func attach(window: NSWindow, model: AppModel) {
        guard task == nil else { return }
        self.window = window
        window.isRestorable = false
        window.setFrameAutosaveName("")
        window.appearance = NSAppearance(named: options.appearance == .dark ? .darkAqua : .aqua)
        applyRequestedSize()
        startDeadline(.seconds(30))
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await prepare(model: model)
                deadline?.cancel()
                try await Task.sleep(for: .seconds(1))
                try await writePNG()
                exit(EXIT_SUCCESS)
            } catch {
                // A cancelled pose is the deadline's to report.
                guard !Task.isCancelled else { return }
                deadline?.cancel()
                await fail(error)
            }
        }
    }

    /// One deadline covers the launch: first for a window to open, then for the pose to be ready.
    private func startDeadline(_ duration: Duration) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self else { return }
            task?.cancel()
            await fail(LaunchArgumentError(timeoutReason))
        }
    }

    private var timeoutReason: String {
        if task == nil { return "No app window opened within 35 seconds" }
        if let requestedState { return "Snapshot state '\(requestedState)' did not become ready" }
        return "Timed out: \(channel?.phase.message ?? "No live channel snapshot arrived")"
    }

    private func fail(_ error: any Error) async -> Never {
        FileHandle.standardError.write(Data("Snapshot failed: \(error.localizedDescription)\n".utf8))
        if window != nil, let output = options.snapshotURL {
            let diagnostic = output.deletingPathExtension().appendingPathExtension("failure.png")
            do { try await writePNG(to: diagnostic, validateSize: false) }
            catch {
                FileHandle.standardError.write(Data("Diagnostic capture failed: \(error.localizedDescription)\n".utf8))
            }
        }
        exit(EXIT_FAILURE)
    }

    private func applyRequestedSize() {
        guard let window else { return }
        let size = NSSize(width: CGFloat(options.width), height: CGFloat(options.height))
        guard window.frame.size != size else { return }
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height,
                               width: size.width, height: size.height), display: true)
    }

    private func prepare(model: AppModel) async throws {
        guard let id = options.channelID, let launchTarget = model.launchTarget else {
            throw LaunchArgumentError("No channel selected")
        }
        if let error = model.configurationError { throw LaunchArgumentError(error) }
        guard let target = await launchTarget.value, let catalog = model.catalogs.first(at: target.serverURL) else {
            throw LaunchArgumentError(model.catalogs.lazy.compactMap(\.phase.message).first ?? "No server lists \(id)")
        }
        let channel = catalog.channel(id: id)
        self.channel = channel
        if options.snapshotState != "handoff-unavailable" {
            for await phase in Observations({ channel.phase }) {
                if phase == .deleted { throw LaunchArgumentError("The selected channel was deleted") }
                if phase.isConnected { break }
            }
            try Task.checkCancellation()
        }
        // At launch SwiftUI briefly restores the split view's saved height as the window's minimum,
        // which can clamp the first resize, so the size is applied again here.
        applyRequestedSize()
        guard let state = options.snapshotState else { return }
        requestedState = state
        for await (isReady, error) in Observations({ (self.isStateReady, self.stateError) }) {
            if let error { throw LaunchArgumentError(error) }
            if isReady { break }
        }
        try Task.checkCancellation()
    }

    private func writePNG(to destination: URL? = nil, validateSize: Bool = true) async throws {
        guard let window, let frameView = window.contentView?.superview,
              let output = destination ?? options.snapshotURL else {
            throw LaunchArgumentError("The app window is unavailable for capture")
        }
        guard !validateSize || (abs(window.frame.width - CGFloat(options.width)) < 1
              && abs(window.frame.height - CGFloat(options.height)) < 1) else {
            throw LaunchArgumentError("The window could not use the requested \(options.width)x\(options.height) size")
        }
        frameView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try await Self.compositedCapture(of: window)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw LaunchArgumentError("The window bitmap could not be encoded as PNG")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try png.write(to: output, options: .atomic)
        let label = validateSize ? "Snapshot" : "Diagnostic capture"
        FileHandle.standardOutput.write(Data("\(label) saved: \(output.path) (\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) pixels)\n".utf8))
    }

    /// Captures the window as the window server composites it, attached sheets included. Drawing
    /// the view tree with `cacheDisplay` or `CALayer.render(in:)` leaves Liquid Glass, list rows and
    /// content scrolled beneath a `safeAreaBar` blank on macOS 26 and later.
    private static func compositedCapture(of window: NSWindow) async throws -> NSBitmapImageRep {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw LaunchArgumentError("ScreenCaptureKit could not find the app window")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: shareable), configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = window.frame.size
        return bitmap
    }
}

private struct WindowSnapshotKey: EnvironmentKey {
    static let defaultValue: WindowSnapshot? = nil
}

extension EnvironmentValues {
    var windowSnapshot: WindowSnapshot? {
        get { self[WindowSnapshotKey.self] }
        set { self[WindowSnapshotKey.self] = newValue }
    }
}

extension View {
    /// Hands the launch's snapshot, if it has one, to every view in the window.
    func windowSnapshot(_ model: AppModel) -> some View {
        environment(\.windowSnapshot, model.snapshot)
    }

    /// This view's part of a snapshot's pose. It runs for each state the snapshot asks for and
    /// returns true once the window shows that state, or false when another view readies it or it
    /// isn't this view's. A thrown error fails the snapshot with its message. Release builds drop it.
    func snapshotPose(_ pose: @escaping @MainActor (_ state: String) async throws -> Bool) -> some View {
        modifier(SnapshotPoseModifier(pose: pose))
    }
}

private struct SnapshotPoseModifier: ViewModifier {
    @Environment(\.windowSnapshot) private var snapshot
    let pose: @MainActor (String) async throws -> Bool

    func body(content: Content) -> some View {
        content.task(id: snapshot?.requestedState) {
            guard let snapshot, let state = snapshot.requestedState else { return }
            do {
                if try await pose(state) { snapshot.markStateReady(state) }
            } catch is CancellationError {
            } catch {
                snapshot.failState(state, message: error.localizedDescription)
            }
        }
    }
}

/// What `bun run snapshot` asks of this window: whether it's a snapshot's, which never marks read
/// or announces, and the state it poses once its channel is live, like `hover-all`.
@propertyWrapper struct SnapshotRequest: DynamicProperty {
    @Environment(\.windowSnapshot) private var snapshot
    var wrappedValue: SnapshotRequest { self }
    var isActive: Bool { snapshot != nil }
    @MainActor var state: String? { snapshot?.requestedState }
}
#else
extension View {
    @inline(__always) func windowSnapshot(_ model: AppModel) -> Self { self }
    @inline(__always) func snapshotPose(_ pose: @escaping @MainActor (_ state: String) async throws -> Bool) -> Self { self }
}

/// Release builds never take a snapshot, so every check of one folds away.
@propertyWrapper struct SnapshotRequest {
    var wrappedValue: SnapshotRequest { self }
    var isActive: Bool { false }
    var state: String? { nil }
}
#endif

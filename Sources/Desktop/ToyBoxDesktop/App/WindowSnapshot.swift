import AppKit
import ToyBoxClient
import Foundation
import Observation
import ScreenCaptureKit
import SwiftUI

@MainActor @Observable
final class WindowSnapshot {
    let options: LaunchOptions
    private(set) var isPreparing = true
    private(set) var requestedState: String?
    private(set) var isStateReady = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var launchWatchdog: Task<Void, Never>?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var stateError: String?

    init(options: LaunchOptions) {
        self.options = options
        launchWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(35)) }
            catch { return }
            guard let self, task == nil else { return }
            FileHandle.standardError.write(Data("Snapshot failed: No app window opened within 35 seconds\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    var appearance: NSAppearance? { NSAppearance(named: options.appearance == .dark ? .darkAqua : .aqua) }

    func markStateReady(_ name: String) {
        // A Handoff may resolve before the snapshot window attaches.
        guard name == options.snapshotState else { return }
        isStateReady = true
    }

    func failState(_ name: String, message: String) {
        guard name == requestedState else { return }
        stateError = message
    }

    func attach(window: NSWindow, model: AppModel) {
        guard task == nil else { return }
        launchWatchdog?.cancel()
        self.window = window
        window.isRestorable = false
        window.setFrameAutosaveName("")
        window.appearance = appearance
        applyRequestedSize()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await prepare(model: model)
                try await Task.sleep(for: .seconds(1))
                try await writePNG()
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("Snapshot failed: \(error.localizedDescription)\n".utf8))
                if let output = options.snapshotURL {
                    let diagnostic = output.deletingPathExtension().appendingPathExtension("failure.png")
                    do { try await writePNG(to: diagnostic, validateSize: false) }
                    catch {
                        FileHandle.standardError.write(Data("Diagnostic capture failed: \(error.localizedDescription)\n".utf8))
                    }
                }
                exit(EXIT_FAILURE)
            }
        }
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
        let deadline = Date.now.addingTimeInterval(25)
        while Date.now < deadline {
            if catalog.channel(id: id).phase.isConnected || options.snapshotState == "handoff-unavailable" {
                // At launch SwiftUI briefly restores the split view's saved height as the window's
                // minimum, which can clamp the first resize, so the size is applied again here.
                applyRequestedSize()
                isPreparing = false
                if let state = options.snapshotState {
                    requestedState = state
                    while !isStateReady, Date.now < deadline {
                        if let error = stateError { throw LaunchArgumentError(error) }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard isStateReady else {
                        throw LaunchArgumentError("Snapshot state '\(state)' did not become ready")
                    }
                }
                return
            }
            if catalog.channel(id: id).phase == .deleted {
                throw LaunchArgumentError("The selected channel was deleted")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let detail = catalog.channel(id: id).phase.message ?? "No live channel snapshot arrived"
        throw LaunchArgumentError("Timed out: \(detail)")
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

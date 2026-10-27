#if DEBUG
import AppKit
import Foundation

@MainActor
enum HandoffProof {
    static func captureIfRequested(window: () -> NSWindow?) async {
        guard let path = ProcessInfo.processInfo.environment["TOY_BOX_HANDOFF_CAPTURE"] else { return }
        do {
            try await Task.sleep(for: .seconds(1))
            guard let window = window() else { throw LaunchArgumentError("The Handoff window is unavailable for capture") }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try await WindowSnapshot.compositedCapture(of: window)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw LaunchArgumentError("The Handoff window could not be encoded as PNG")
            }
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: output, options: .atomic)
            FileHandle.standardOutput.write(Data("Handoff capture saved: \(path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Handoff capture failed: \(error.localizedDescription)\n".utf8))
        }
    }
}
#endif

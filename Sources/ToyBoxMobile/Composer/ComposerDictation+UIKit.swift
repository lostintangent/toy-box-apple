import AVFoundation
import ChannelClient
import OSLog
import Speech
import UIKit

extension DictationSystem {
    static var live: DictationSystem {
        var system = DictationSystem(
            supportedLocale: DictationRecognizer.preferredLocale,
            hasMicrophone: { await Task.detached { AVCaptureDevice.default(for: .audio) != nil }.value },
            microphoneAccess: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: .granted
                case .notDetermined: .undetermined
                default: .denied
                }
            },
            requestMicrophoneAccess: { await AVCaptureDevice.requestAccess(for: .audio) },
            speechRecognitionDenied: {
                [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus())
            },
            installAssets: DictationRecognizer.installAssets,
            makeSource: { MobileDictationAudioSource() },
            makeRecognizer: { DictationRecognizer(locale: $0, contextualStrings: $1, source: $2) },
            announce: { UIAccessibility.post(notification: .announcement, argument: $0) },
            openSettings: { _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else {
                    preconditionFailure("The native application Settings URL must be valid.")
                }
                UIApplication.shared.open(url, options: [:]) { opened in
                    if !opened {
                        Logger(subsystem: "dev.toybox.mobile", category: "Dictation")
                            .error("Application Settings could not be opened.")
                    }
                }
            }
        )
        system.refreshNotifications += [
            UIApplication.didBecomeActiveNotification, AVAudioSession.routeChangeNotification,
        ]
        return system
    }
}

extension DictationAccess {
    var title: String {
        self == .microphone ? "Microphone Access Is Off" : "Speech Recognition Access Is Off"
    }

    var explanation: String {
        self == .microphone
            ? "Allow Toy Box to use the microphone in Settings. Keyboard dictation still works."
            : "Allow Toy Box to use speech recognition in Settings. Keyboard dictation still works."
    }
}

private final class MobileDictationAudioSource: DictationAudioSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.toybox.mobile", category: "Dictation")
    private let source = MicrophoneDictationSource()
    private var deactivation: (any NSObjectProtocol)?
    private var isActive = false

    func start(format: AVAudioFormat, handler: @escaping @Sendable (DictationAudioEvent) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)
        isActive = true
        deactivation = NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main
        ) { _ in handler(.unavailable) }
        do {
            try source.start(format: format, handler: handler)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
        deactivation = nil
        source.stop()
        guard isActive else { return }
        isActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.error("Dictation audio session could not deactivate: \(error.localizedDescription)")
        }
    }
}

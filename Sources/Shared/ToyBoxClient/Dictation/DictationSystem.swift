import AVFoundation
import Foundation
import Speech

/// The platform services dictation depends on. Tests and snapshot states replace them.
@MainActor package struct DictationSystem {
    package var supportedLocale: () async -> Locale?
    /// Finding the default input device starts Core Audio, so only the first click asks.
    package var hasMicrophone: () async -> Bool
    package var microphoneAccess: () -> DictationMicrophoneAccess
    package var requestMicrophoneAccess: () async -> Bool
    package var speechRecognitionDenied: () -> Bool
    /// Installs the language asset if needed, reporting progress only when a download is required.
    package var installAssets: (Locale, @escaping @MainActor @Sendable (Double) -> Void) async throws -> Void
    package var makeSource: () -> DictationAudioSource
    package var makeRecognizer: (Locale, [String], DictationAudioSource) -> any DictationRecognizing
    package var announce: (String) -> Void
    package var openSettings: (DictationAccess) -> Void
    package var silenceTimeout: Duration
    package var finalizeTimeout: Duration
    package var refreshNotifications: [Notification.Name] = [
        AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
    ]

    package init(
        supportedLocale: @escaping () async -> Locale?,
        hasMicrophone: @escaping () async -> Bool,
        microphoneAccess: @escaping () -> DictationMicrophoneAccess,
        requestMicrophoneAccess: @escaping () async -> Bool,
        speechRecognitionDenied: @escaping () -> Bool,
        installAssets: @escaping (Locale, @escaping @MainActor @Sendable (Double) -> Void) async throws -> Void,
        makeSource: @escaping () -> DictationAudioSource,
        makeRecognizer: @escaping (Locale, [String], DictationAudioSource) -> any DictationRecognizing,
        announce: @escaping (String) -> Void,
        openSettings: @escaping (DictationAccess) -> Void,
        silenceTimeout: Duration = .seconds(30),
        finalizeTimeout: Duration = .seconds(3)
    ) {
        self.supportedLocale = supportedLocale
        self.hasMicrophone = hasMicrophone
        self.microphoneAccess = microphoneAccess
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.speechRecognitionDenied = speechRecognitionDenied
        self.installAssets = installAssets
        self.makeSource = makeSource
        self.makeRecognizer = makeRecognizer
        self.announce = announce
        self.openSettings = openSettings
        self.silenceTimeout = silenceTimeout
        self.finalizeTimeout = finalizeTimeout
    }
}

package enum DictationMicrophoneAccess: Equatable {
    case undetermined, denied, granted
}

/// Which permission keeps the Dictate button from listening.
package enum DictationAccess: Equatable {
    case microphone, speechRecognition

    package var title: String {
        self == .microphone ? "Microphone Access Is Off" : "Speech Recognition Access Is Off"
    }
}

extension DictationSystem {
    /// The device's microphone, permissions and on-device transcriber, with each app's audio source,
    /// announcements and Settings link.
    package static func device(makeSource: @escaping () -> DictationAudioSource,
                               announce: @escaping (String) -> Void,
                               openSettings: @escaping (DictationAccess) -> Void) -> DictationSystem {
        DictationSystem(
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
            speechRecognitionDenied: { [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus()) },
            installAssets: DictationRecognizer.installAssets,
            makeSource: makeSource,
            makeRecognizer: { DictationRecognizer(locale: $0, contextualStrings: $1, source: $2) },
            announce: announce,
            openSettings: openSettings
        )
    }

    /// Deterministic services for snapshot states and tests, with scripted words instead of audio.
    package static func scripted(microphone: DictationMicrophoneAccess = .granted, hasMicrophone: Bool = true,
                         downloadProgress: Double? = nil, results: [(String, Bool)] = [],
                         level: Double = 0.75, finishes: Bool = true) -> DictationSystem {
        DictationSystem(
            supportedLocale: { Locale(identifier: "en_US") },
            hasMicrophone: { hasMicrophone },
            microphoneAccess: { microphone },
            requestMicrophoneAccess: { false },
            speechRecognitionDenied: { false },
            installAssets: { _, progress in
                guard let downloadProgress else { return }
                progress(downloadProgress)
                try await Task.sleep(for: .seconds(3_600))
            },
            makeSource: { SilentDictationSource() },
            makeRecognizer: { _, _, _ in
                ScriptedDictationRecognizer(results: results, level: level, finishes: finishes)
            },
            announce: { _ in },
            openSettings: { _ in }
        )
    }
}

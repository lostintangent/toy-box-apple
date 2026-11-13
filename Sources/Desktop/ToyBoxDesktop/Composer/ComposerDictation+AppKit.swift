import AppKit
import ChannelClient
import ToyBoxUI

extension ComposerDictation {
    convenience init() { self.init(system: .live) }
}

extension DictationAccess {
    var explanation: String {
        self == .microphone
            ? "Allow Toy Box to use the microphone in Privacy & Security settings. The Dictation key still works."
            : "Allow Toy Box to use speech recognition in Privacy & Security settings. The Dictation key still works."
    }

    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?"
            + (self == .microphone ? "Privacy_Microphone" : "Privacy_SpeechRecognition"))
    }
}

extension DictationSystem {
    static var live: DictationSystem {
        var system = DictationSystem.device(
            // The microphone would hear the reader's voice.
            makeSource: { TranscriptReadAloud.Microphone(MicrophoneDictationSource()) },
            announce: { message in
                guard let element = NSApp.keyWindow ?? NSApp.mainWindow else { return }
                NSAccessibility.post(element: element, notification: .announcementRequested,
                                     userInfo: [.announcement: message,
                                                .priority: NSAccessibilityPriorityLevel.high.rawValue])
            },
            openSettings: { access in
                if let url = access.settingsURL { NSWorkspace.shared.open(url) }
            }
        )
        system.refreshNotifications.append(NSApplication.didBecomeActiveNotification)
#if DEBUG
        if let url = recordingOverride {
            system.hasMicrophone = { true }
            system.microphoneAccess = { .granted }
            system.makeSource = { FileDictationSource(url: url) }
        }
#endif
        return system
    }

#if DEBUG
    /// Lets real-window checks feed a recording through the real transcriber without a microphone.
    static var recordingOverride: URL? {
        ProcessInfo.processInfo.environment["TOYBOX_DICTATION_AUDIO_FILE"].map { URL(fileURLWithPath: $0) }
    }
#endif
}

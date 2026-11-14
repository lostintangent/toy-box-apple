import Foundation
import SwiftUI
import Testing
import ToyBoxUI
#if canImport(UIKit)
import UIKit
#endif

struct DesignTests {
    @Test(arguments: [
        (0, [Int]()), (1, [1]), (2, [2]), (3, [3, 1]), (4, [3, 2, 1]), (8, [3, 2, 1]),
    ])
    func smallerAvatarStacksOnlyReplaceAtLeastTwoFaces(count: Int, limits: [Int]) {
        #expect(AgentAvatarStack.faceLimits(for: count) == limits)
    }

    #if canImport(UIKit)
    @Test @MainActor func phoneSecondaryInkClearsTextContrast() {
        func rgb(_ color: UIColor, traits: UITraitCollection) -> TranscriptRGB {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            #expect(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            return TranscriptRGB(red: red, green: green, blue: blue, alpha: alpha)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let ink = rgb(UIColor(ChannelInk.secondary), traits: traits)
            #expect(ink.alpha == 1)
            let canvas = rgb(.systemBackground, traits: traits)
            let surfaces = [
                canvas, rgb(.secondarySystemBackground, traits: traits),
                rgb(.tertiarySystemBackground, traits: traits),
                canvas.under(rgb(.tertiarySystemFill, traits: traits)),
                rgb(style == .light ? UIColor(white: 0xEE / 255, alpha: 1)
                    : UIColor(white: 0x2C / 255, alpha: 1), traits: traits),
            ]
            for background in surfaces {
                #expect(ink.contrast(with: background) >= 4.5)
            }
        }
    }
    #endif

    @Test func avatarHexColorsKeepShorthandAndInvalidInputRules() {
        let expected = Color(.sRGB, red: 170.0 / 255, green: 187.0 / 255, blue: 204.0 / 255)
        #expect(["#abc", "abc", "#aAbBcC", "AABBCC"].allSatisfy { Color(hex: $0) == expected })
        #expect(["", "#12", "#12345", "#1234567", "#12ggff"].allSatisfy { Color(hex: $0) == nil })
    }

    @Test func systemEventsLeadWithTheirOwnSymbolAndUnknownOnesWithInfo() {
        #expect(ChannelSystemEventStyle.symbol(for: "tasks_completed") == "checkmark.circle.fill")
        for scheme in [ColorScheme.light, .dark] {
            #expect(ChannelSystemEventStyle.symbolColor(for: "tasks_completed", in: scheme)
                    == ChannelTaskColors.changes(in: scheme).added)
        }
        #expect(ChannelSystemEventStyle.symbol(for: "a_future_event") == "info.circle")
    }

    @Test func aHiddenTaskClockNeverTicksAndAVisibleOneRepeats() {
        let start = Date(timeIntervalSince1970: 125)
        #expect(Array(ChannelTaskMinuteSchedule(isVisible: false).entries(from: start, mode: .normal)) == [start])
        let ticks = Array(ChannelTaskMinuteSchedule(isVisible: true).entries(from: start, mode: .normal).prefix(3))
        #expect(ticks.count == 3)
    }
}

import Foundation
import SwiftUI
import Testing
import ToyBoxUI
#if canImport(UIKit)
import UIKit
#endif

struct DesignTests {
    @Test(arguments: [
        (-1, [Int]()), (0, []), (1, [1]), (2, [2]), (3, [3, 1]), (4, [3, 2, 1]), (8, [3, 2, 1]),
    ])
    func smallerAvatarStacksOnlyReplaceAtLeastTwoFaces(count: Int, limits: [Int]) {
        #expect(AgentAvatarStack.faceLimits(for: count) == limits)
    }

    @Test @MainActor func sharedSecondaryInkPreservesMacAndClearsPhoneTextContrast() {
        #if canImport(UIKit)
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
        #else
        #expect(ChannelInk.secondary == Color.secondary)
        #endif
    }

    @Test func overviewSecondaryInkUsesTheApprovedOpaqueSRGBValues() {
        let light = ChannelOverviewInk.secondary(in: .light).resolve(in: EnvironmentValues())
        let dark = ChannelOverviewInk.secondary(in: .dark).resolve(in: EnvironmentValues())
        #expect(abs(light.red - 99.0 / 255) < 0.00001)
        #expect(abs(light.green - 99.0 / 255) < 0.00001)
        #expect(abs(light.blue - 102.0 / 255) < 0.00001 && light.opacity == 1)
        #expect(abs(dark.red - 174.0 / 255) < 0.00001)
        #expect(abs(dark.green - 174.0 / 255) < 0.00001)
        #expect(abs(dark.blue - 178.0 / 255) < 0.00001 && dark.opacity == 1)
    }

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

    @Test func disabledScheduleHasNoRepeatingEntriesAndVisibleTicksUseMinuteBoundaries() {
        let start = Date(timeIntervalSince1970: 125)
        #expect(Array(ChannelTaskMinuteSchedule(isVisible: false).entries(from: start, mode: .normal)) == [start])
        let ticks = Array(ChannelTaskMinuteSchedule(isVisible: true).entries(from: start, mode: .normal).prefix(3))
        #expect(ticks.count == 3)
        #expect(ticks.allSatisfy { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 })
        #expect(ticks[1].timeIntervalSince(ticks[0]) == 60 && ticks[2].timeIntervalSince(ticks[1]) == 60)
    }
}

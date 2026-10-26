import ChannelKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ToyBoxUI

struct OverviewPresentationTests {
    @Test func countsKeepKnownZeroUnavailableAndNaturalSingularPluralDistinct() {
        let empty = ChannelOverviewSummary.tasks(channelTasksProgress([]))
        #expect(empty.count == "0" && empty.spoken == "Tasks, no tasks")
        let one = ChannelOverviewSummary.tasks(channelTasksProgress([
            ChannelTask(id: "one", title: "One", status: "done"),
        ]))
        #expect(one.count == "1/1" && one.spoken == "Tasks, 1 of 1 top-level task complete")
        let two = ChannelOverviewSummary.tasks(channelTasksProgress([
            ChannelTask(id: "one", title: "One", status: "done"),
            ChannelTask(id: "two", title: "Two", status: "pending"),
        ]))
        #expect(two.count == "1/2" && two.spoken == "Tasks, 1 of 2 top-level tasks complete")
        let cases: [(ChannelOverviewSummary, String)] = [
            (.team(1), "Team, 1 agent"), (.team(9), "Team, 9 agents"),
            (.artifacts(1), "Artifacts, 1 shared artifact"), (.artifacts(2), "Artifacts, 2 shared artifacts"),
            (.routines(1), "Routines, 1 routine"), (.routines(0), "Routines, 0 routines"),
        ]
        for (summary, spoken) in cases { #expect(summary.spoken == spoken) }
        for summary in [ChannelOverviewSummary.team(nil), .tasks(nil), .artifacts(nil), .routines(nil)] {
            #expect(summary.count == "Unavailable")
            #expect(summary.spoken == "\(summary.title), count unavailable")
        }
    }

    @Test func metadataUsesExactSpacingAndReflowsOnlyBelowTheMeasuredBoundary() {
        #expect(ChannelOverviewFactsLayout.titleGap == 6)
        let exact = layout(width: 223)
        #expect(exact.frames[1].minX - exact.frames[0].maxX == 12)
        #expect(exact.frames[2].minX - exact.frames[1].maxX == 16)
        #expect(exact.frames.allSatisfy { $0.minY == 0 })
        #expect(exact.frames[2].maxX == 223)
        for width: CGFloat in [222.99, 192] {
            let reflowed = layout(width: width)
            #expect(reflowed.frames[2].minY - reflowed.frames[0].maxY == 4)
            #expect(reflowed.frames[2].maxX == width)
        }
        #expect(layout(width: 223.01).frames.allSatisfy { $0.minY == 0 })
    }

    @Test func headerKeepsItsSixPointCountGapAndReflowsWholeFactsBeforeTheCount() {
        #expect(ChannelOverviewHeaderLayout.nameCountGap == 6)
        let sizes = [CGSize(width: 40, height: 18), CGSize(width: 30, height: 16),
                     CGSize(width: 80, height: 14), CGSize(width: 16, height: 16)]
        #expect(ChannelOverviewHeaderLayout.reflow(width: 192, items: sizes, stacksLeading: false) == .inline)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 191.99, items: sizes, stacksLeading: false) == .factsBelow)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 104, items: sizes, stacksLeading: false) == .factsBelow)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 103.99, items: sizes, stacksLeading: false) == .stacked)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 500, items: sizes, stacksLeading: true) == .stacked)
        #expect(ChannelOverviewTaskDiff.spoken(.init(added: 1, removed: 1)) == "1 addition, 1 deletion")
    }

    @Test func indentedRowsKeepTheDiffOnTheAvatarsTrailingRail() {
        let trailingEdge: CGFloat = 334
        for indent: CGFloat in [0, 22, 44, 66, 88] {
            let lane = layout(width: trailingEdge - indent - 22)
            #expect(indent + 22 + lane.frames[2].maxX == trailingEdge)
        }
    }

    @Test func accessibilityStacksElapsedCheckInThenDiffAtTheLeadingEdge() {
        let result = layout(width: 500, stacksLeading: true)
        #expect(result.frames.map(\.minX) == [0, 0, 0])
        #expect(result.frames.map(\.minY) == [0, 18, 36])
        #expect(result.frames.map(\.size) == items.map(\.size))
        let narrow = layout(width: 126.99)
        #expect(narrow.frames[1].minY == 18)
        #expect(narrow.frames[2].minY == 36 && narrow.frames[2].maxX == 126.99)
    }

    @Test func mixedNativeTextBaselinesRemainAligned() {
        let items = [
            ChannelOverviewMeasuredItem(size: .init(width: 70, height: 16), baseline: 12),
            ChannelOverviewMeasuredItem(size: .init(width: 45, height: 14), baseline: 10),
            ChannelOverviewMeasuredItem(size: .init(width: 80, height: 18), baseline: 13),
        ]
        let result = ChannelOverviewFactsLayout.arrange(width: 300, items: items, timeCount: 2, stacksLeading: false)
        #expect(zip(result.frames, items).allSatisfy { frame, item in frame.minY + item.baseline == 13 })
        #expect(result.size.height == 18)
    }

    @Test func routineRunCopyKeepsPendingAheadOfAcknowledgementAndOtherwisePreservesTheSchedule() {
        let requested = Date(timeIntervalSince1970: 1)
        #expect(ChannelRoutineRunPresentation.label(
            schedule: "Every morning", pending: false, requestedAt: nil) == "Every morning")
        #expect(ChannelRoutineRunPresentation.label(
            schedule: "Every morning", pending: true, requestedAt: nil) == "Requesting run…")
        #expect(ChannelRoutineRunPresentation.label(
            schedule: "Every morning", pending: false, requestedAt: requested) == "Run requested")
        #expect(ChannelRoutineRunPresentation.label(
            schedule: "Every morning", pending: true, requestedAt: requested) == "Requesting run…")
    }

    @Test(arguments: [1.0, 2.0, 3.0], [false, true])
    @MainActor
    func sharedAncestryGuideKeepsOnePixelAndFourPointEndsInBothDirections(
        scale: CGFloat, rightToLeft: Bool
    ) throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try rendered(
                ChannelTaskAncestryGuide(statusWidth: 16)
                    .frame(width: 60, height: 80)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.displayScale, scale)
                    .environment(\.colorScheme, scheme)
                    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight),
                scale: scale)
            let background: UInt8 = scheme == .dark ? 0 : 255
            var columns = Set<Int>()
            var rows = Set<Int>()
            for y in 0..<image.height {
                for x in 0..<image.width {
                    if image.pixels[(y * image.width + x) * 4] != background {
                        columns.insert(x)
                        rows.insert(y)
                    }
                }
            }
            let column = Int((8 * scale - 0.5).rounded())
            #expect(columns == [rightToLeft ? image.width - 1 - column : column])
            #expect(rows.min() == Int(4 * scale))
            #expect(rows.max() == Int(76 * scale) - 1)
        }
    }

    @Test(arguments: ["done", "blocked", "in_progress", "pending", "unknown"], [16.0, 24.0])
    @MainActor
    func sharedStatusSymbolPreservesNativeGlyphWeightPaletteAndHostSecondaryInk(
        status: String, size: CGFloat
    ) throws {
        for scheme in [ColorScheme.light, .dark] {
            let secondary: Color = size == 16 ? .secondary : ChannelInk.secondary
            let background: Color = scheme == .dark ? .black : .white
            let actual = try rendered(
                ChannelTaskStatusSymbol(status: status, secondary: secondary)
                    .font(.system(size: size * 0.875))
                    .frame(width: size, height: size)
                    .background(background)
                    .environment(\.colorScheme, scheme))
            let expected = try rendered(
                nativeStatusReference(status: status, size: size, secondary: secondary, scheme: scheme)
                    .frame(width: size, height: size)
                    .background(background)
                    .environment(\.colorScheme, scheme))
            #expect(actual.width == expected.width && actual.height == expected.height)
            let largestDifference = try #require(zip(actual.pixels, expected.pixels)
                .map { abs(Int($0) - Int($1)) }.max())
            // Native style paths can quantize an 8-bit color component one level apart.
            #expect(largestDifference <= 1, "Status \(status), size \(size), scheme \(scheme)")
        }
    }

    @ViewBuilder
    private func nativeStatusReference(status: String, size: CGFloat, secondary: Color,
                                       scheme: ColorScheme) -> some View {
        let symbol = status == "done" ? "checkmark.circle.fill"
            : status == "blocked" ? "exclamationmark.circle.fill"
            : status == "in_progress" ? "circle.lefthalf.filled" : "circle"
        if size == 24 {
            Image(systemName: symbol)
                .symbolRenderingMode(status == "blocked" ? .palette : .monochrome)
                .foregroundStyle(status == "blocked" ? Color.white
                                 : status == "done" ? ChannelTaskColors.changes(in: scheme).added : secondary,
                                 Color.red)
                .font(.system(size: size * 0.875,
                              weight: status == "done" || status == "blocked" ? .semibold : .regular))
        } else {
            Group {
                if status == "done" {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.monochrome)
                        .fontWeight(.semibold)
                        .foregroundStyle(ChannelTaskColors.changes(in: scheme).added)
                } else if status == "blocked" {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.palette)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white, .red)
                } else {
                    Image(systemName: symbol).foregroundStyle(secondary)
                }
            }
            .font(.system(size: size * 0.875))
        }
    }

    @MainActor
    private func rendered(_ content: some View, scale: CGFloat = 3) throws
        -> (width: Int, height: Int, pixels: [UInt8]) {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return (image.width, image.height, pixels)
    }

    private var items: [ChannelOverviewMeasuredItem] {
        [70.0, 45, 80].map { .init(size: .init(width: $0, height: 14), baseline: 11) }
    }

    private func layout(width: CGFloat, stacksLeading: Bool = false) -> (size: CGSize, frames: [CGRect]) {
        ChannelOverviewFactsLayout.arrange(width: width, items: items, timeCount: 2, stacksLeading: stacksLeading)
    }
}

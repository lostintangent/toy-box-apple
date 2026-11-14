import ToyBoxKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ToyBoxUI

struct ChannelOverviewTests {
    @Test func countsKeepKnownZeroUnavailableAndNaturalSingularPluralDistinct() {
        let empty = ChannelOverviewSummary.tasks(([] as [ChannelTask]).progress)
        #expect(empty.count == "0" && empty.spoken == "Tasks, no tasks")
        let one = ChannelOverviewSummary.tasks([
            ChannelTask(id: "one", title: "One", status: "done"),
        ].progress)
        #expect(one.count == "1/1" && one.spoken == "Tasks, 1 of 1 top-level task complete")
        let two = ChannelOverviewSummary.tasks([
            ChannelTask(id: "one", title: "One", status: "done"),
            ChannelTask(id: "two", title: "Two", status: "pending"),
        ].progress)
        #expect(two.count == "1/2" && two.spoken == "Tasks, 1 of 2 top-level tasks complete")
        let cases: [(ChannelOverviewSummary, String)] = [
            (.team(1), "Team Members, 1 agent"), (.team(9), "Team Members, 9 agents"),
            (.artifacts(1), "Artifacts, 1 shared artifact"), (.artifacts(2), "Artifacts, 2 shared artifacts"),
            (.routines(1), "Routines, 1 routine"), (.routines(0), "Routines, 0 routines"),
        ]
        for (summary, spoken) in cases { #expect(summary.spoken == spoken) }
        for summary in [ChannelOverviewSummary.team(nil), .tasks(nil), .artifacts(nil), .routines(nil)] {
            #expect(summary.count == "Unavailable")
            #expect(summary.spoken == "\(summary.title), count unavailable")
        }
    }

    @Test func workingFilterKeepsExactlyTheAgentsWhoseRowShowsTheWorkingCue() {
        #expect(ChannelOverviewFilter.keepsWorkingAgent(presence: .init(state: "working"), isAvailable: true))
        for presence: ChannelAgentPresence? in [nil, .init(state: "waiting"), .init(state: "idle")] {
            #expect(!ChannelOverviewFilter.keepsWorkingAgent(presence: presence, isAvailable: true))
        }
        let disconnected = ChannelOverviewFilter.keepsWorkingAgent(presence: .init(state: "working"), isAvailable: false)
        #expect(disconnected == false, "disconnected working agent kept: \(disconnected)")
    }

    @Test func anEmptyWorkingFilterSaysNobodyIsWorkingOnlyWhileItCanKnow() {
        #expect(ChannelOverviewFilter.noWorkingAgentsText(isAvailable: true) == "No agents working")
        let offline = ChannelOverviewFilter.noWorkingAgentsText(isAvailable: false)
        #expect(offline == "Status unavailable while disconnected")
    }

    @Test func metadataUsesExactSpacingAndReflowsOnlyBelowTheMeasuredBoundary() {
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

    @Test func headerReflowsWholeFactsBeforeTheCount() {
        let sizes = [CGSize(width: 40, height: 18), CGSize(width: 30, height: 16),
                     CGSize(width: 80, height: 14), CGSize(width: 16, height: 16)]
        #expect(ChannelOverviewHeaderLayout.reflow(width: 192, items: sizes, stacksLeading: false) == .inline)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 191.99, items: sizes, stacksLeading: false) == .factsBelow)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 104, items: sizes, stacksLeading: false) == .factsBelow)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 103.99, items: sizes, stacksLeading: false) == .stacked)
        #expect(ChannelOverviewHeaderLayout.reflow(width: 500, items: sizes, stacksLeading: true) == .stacked)
        #expect(ChannelOverviewTaskDiff.spoken(.init(added: 1, removed: 1)) == "1 addition, 1 deletion")
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

    @MainActor
    @Test func onlyLiveWorkingStatusUsesTheStrongerForegroundInk() {
        let working = ChannelAgent.StatusLine(presence: .init(state: "working"), isAvailable: true)
        #expect(working.textColor == Color.primary.opacity(0.85))
        for presence: ChannelAgentPresence? in [nil, .init(state: "waiting"), .init(state: "idle")] {
            #expect(ChannelAgent.StatusLine(presence: presence, isAvailable: true).textColor == ChannelInk.secondary)
        }
        #expect(ChannelAgent.StatusLine(presence: .init(state: "working"), isAvailable: false).textColor == ChannelInk.secondary)
    }

    @Test(arguments: [1.0, 2.0, 3.0], [false, true])
    @MainActor
    func sharedAncestryGuideKeepsHostRuleWeightAndFourPointEndsInBothDirections(
        scale: CGFloat, rightToLeft: Bool
    ) throws {
        let image = try rendered(
            ChannelTaskAncestryGuide(statusWidth: 16)
                .frame(width: 60, height: 80)
                .background(Color.black)
                .environment(\.displayScale, scale)
                .environment(\.colorScheme, .dark)
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight),
            scale: scale)
        var columns = Set<Int>()
        var rows = Set<Int>()
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixels[(y * image.width + x) * 4] != 0 {
                columns.insert(x)
                rows.insert(y)
            }
        }
        let width = scale
        let firstColumn = Int((8 * scale - width / 2).rounded())
        let expected = Set((firstColumn..<(firstColumn + Int(width))).map {
            rightToLeft ? image.width - 1 - $0 : $0
        })
        #expect(columns == expected)
        #expect(rows.min() == Int(4 * scale))
        #expect(rows.max() == Int(76 * scale) - 1)
    }

    /// Draws into the test's own bitmap. `ImageRenderer.cgImage` returns an image-provider CGImage that
    /// rasterizes through an IOSurface on first draw, the path that failed CI (t510 and t603). Every caller
    /// fills an opaque background, so a transparent pixel marks an incomplete render.
    @MainActor
    private func rendered(_ content: some View, scale: CGFloat = 3) throws
        -> (width: Int, height: Int, pixels: [UInt8]) {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var image: (width: Int, height: Int, pixels: [UInt8])?
        renderer.render(rasterizationScale: scale) { size, draw in
            let width = Int((size.width * scale).rounded(.up))
            let height = Int((size.height * scale).rounded(.up))
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.scaleBy(x: scale, y: scale)
                draw(context)
            }
            image = (width, height, pixels)
        }
        let result = try #require(image)
        let opaque = stride(from: 3, to: result.pixels.count, by: 4).allSatisfy { result.pixels[$0] == 255 }
        try #require(opaque, "Incomplete render: an opaque background left transparent pixels.")
        return result
    }

    private var items: [ChannelOverviewMeasuredItem] {
        [70.0, 45, 80].map { .init(size: .init(width: $0, height: 14), baseline: 11) }
    }

    private func layout(width: CGFloat, stacksLeading: Bool = false) -> (size: CGSize, frames: [CGRect]) {
        ChannelOverviewFactsLayout.arrange(width: width, items: items, timeCount: 2, stacksLeading: stacksLeading)
    }
}

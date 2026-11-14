import ToyBoxKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ToyBoxUI

struct ChannelOverviewTests {
    @Test func artifactSymbolsKeepTheSameFileTypeMeaningOnBothHosts() {
        let cases: [(String, String)] = [
            ("plan.md", "doc.text"), ("plan.MARKDOWN", "doc.text"), ("data.bin", "doc.text"),
            ("page.html", "chevron.left.forwardslash.chevron.right"),
            ("page.HTM", "chevron.left.forwardslash.chevron.right"),
            ("diagram.svg", "square.on.circle"), ("photo.png", "photo"), ("photo.jpeg", "photo"),
        ]
        for (path, expected) in cases {
            let artifact = ChannelArtifact(file: .init(kind: "machine", path: path), title: path)
            #expect(ArtifactContentKind(artifact).symbolName == expected)
        }
    }

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
        #expect(offline == ChannelAgent.StatusLine(presence: .init(state: "working"), isAvailable: false).text)
    }

    @Test func filtersNameTheirToggleAndIdentifyItForBothHosts() {
        var isOn = false
        let binding = Binding(get: { isOn }, set: { isOn = $0 })
        let tasks = ChannelOverviewFilter.inProgressTasks(binding)
        #expect(tasks.title == "Show Only In-Progress Tasks")
        #expect(tasks.identifier == "overview-tasks-in-progress-filter")
        let team = ChannelOverviewFilter.workingAgents(binding)
        #expect(team.title == "Show Only Working Agents")
        #expect(team.identifier == "overview-team-working-filter")
        team.isOn.wrappedValue = true
        #expect(isOn)
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

    @MainActor
    @Test func waitingAmberUsesTheApprovedOpaqueSRGBValues() {
        let light = ChannelAgent.StatusLine.waitingCue(in: .light).resolve(in: EnvironmentValues())
        let dark = ChannelAgent.StatusLine.waitingCue(in: .dark).resolve(in: EnvironmentValues())
        #expect(abs(light.red - 154.0 / 255) < 0.00001)
        #expect(abs(light.green - 103.0 / 255) < 0.00001 && light.blue == 0 && light.opacity == 1)
        #expect(abs(dark.red - 244.0 / 255) < 0.00001)
        #expect(abs(dark.green - 190.0 / 255) < 0.00001)
        #expect(abs(dark.blue - 102.0 / 255) < 0.00001 && dark.opacity == 1)
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

    @Test(arguments: [11.0, 13, 36], [1.0, 2, 3])
    @MainActor
    func wakeCountdownLeavesFourPointsBetweenItsBellAndDuration(fontSize: Double, scale: Double) throws {
        func width<Content: View>(_ content: Content) throws -> Int {
            let renderer = ImageRenderer(content: content.font(.system(size: fontSize)).fixedSize())
            renderer.scale = scale
            return try #require(renderer.cgImage).width
        }
        let countdown = try width(ChannelAgentWakeCountdown(wake: .distantPast, isActive: false))
        let withoutGap = try width(HStack(spacing: 0) {
            Image(systemName: "bell")
            Text("Due").monospacedDigit()
        })
        #expect(countdown - withoutGap == Int(4 * scale))
    }

    @Test(arguments: [1.0, 2.0, 3.0], [false, true])
    @MainActor
    func sharedAncestryGuideKeepsHostRuleWeightAndFourPointEndsInBothDirections(
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
            let width = scale
            let firstColumn = Int((8 * scale - width / 2).rounded())
            let expected = Set((firstColumn..<(firstColumn + Int(width))).map {
                rightToLeft ? image.width - 1 - $0 : $0
            })
            #expect(columns == expected)
            #expect(rows.min() == Int(4 * scale))
            #expect(rows.max() == Int(76 * scale) - 1)
        }
    }

    #if os(macOS)
    @Test(arguments: [1.0, 2.0, 3.0])
    @MainActor
    func macDividerKeepsTheSameWeightAsTheAncestryGuide(scale: CGFloat) throws {
        let image = try rendered(
            VStack(spacing: 0) { Divider() }
                .frame(width: 60, height: 80)
                .background(Color.white)
                .environment(\.displayScale, scale)
                .environment(\.colorScheme, .light),
            scale: scale)
        let rows = Set((0..<image.height).filter { y in
            image.pixels[(y * image.width + image.width / 2) * 4] != 255
        })
        #expect(rows.count == Int(scale))
    }
    #endif

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

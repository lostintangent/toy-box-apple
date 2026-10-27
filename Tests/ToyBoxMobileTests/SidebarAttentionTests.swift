import ChannelKit
import SwiftUI
import Testing
import ToyBoxUI
import UIKit
@testable import ToyBoxMobile

@MainActor
struct SidebarAttentionTests {
    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func unreadAddsOnlyATrailingSevenPointDot(scheme: ColorScheme, selected: Bool) throws {
        let plain = try render(attention: nil, scheme: scheme, selected: selected)
        let unread = try render(attention: .unread, scheme: scheme, selected: selected)
        #expect(unread.width == plain.width && unread.height == plain.height)
        let before = try pixels(plain)
        let after = try pixels(unread)
        let changed = (0..<(unread.width * unread.height)).filter { pixel in
            let start = pixel * 4
            return before[start..<(start + 4)] != after[start..<(start + 4)]
        }
        let left = try #require(changed.map { $0 % unread.width }.min())
        let right = try #require(changed.map { $0 % unread.width }.max())
        let top = try #require(changed.map { $0 / unread.width }.min())
        let bottom = try #require(changed.map { $0 / unread.width }.max())
        #expect(right - left + 1 == 21, "Only the 7pt dot may be drawn, not an Unread label.")
        #expect(bottom - top + 1 == 21)
        #expect(right == unread.width - 1, "The dot keeps its trailing position.")

        let expected = selected ? Color.white : ChannelAttentionStyle.color(for: .unread, in: scheme)
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let color = UIColor(expected).resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let center = (((top + bottom) / 2) * unread.width + (left + right) / 2) * 4
        for (index, component) in [red, green, blue].enumerated() {
            #expect(abs(Int(after[center + index]) - Int((component * 255).rounded())) <= 1)
        }
    }

    @Test(arguments: [ChannelAttention.waiting, .finished], [ColorScheme.light, .dark])
    func otherAttentionStatesDrawOnlyTheirTrailingSymbol(attention: ChannelAttention, scheme: ColorScheme) throws {
        let plain = try render(attention: nil, scheme: scheme, selected: false)
        let marked = try render(attention: attention, scheme: scheme, selected: false)
        #expect(marked.width == plain.width && marked.height == plain.height)
        let before = try pixels(plain)
        let after = try pixels(marked)
        let changed = (0..<(marked.width * marked.height)).filter { pixel in
            let start = pixel * 4
            return before[start..<(start + 4)] != after[start..<(start + 4)]
        }
        let left = try #require(changed.map { $0 % marked.width }.min())
        let right = try #require(changed.map { $0 % marked.width }.max())
        #expect(right - left + 1 <= 60, "A status symbol must not include visible status words.")
        #expect(right >= marked.width - 6, "The symbol stays at the row's trailing edge.")
    }

    #if DEBUG
    @Test(arguments: [ChannelAttention.unread, .waiting, .finished], [ColorScheme.light, .dark])
    func attentionRemainsSpokenInTheSingleChannelAccessibilityElement(
        attention: ChannelAttention, scheme: ColorScheme
    ) throws {
        let host = UIHostingController(rootView: row(attention: attention)
            .environment(\.colorScheme, scheme)
            .dynamicTypeSize(.large))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 100))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let elements = MobileAutomationTree(windows: [window]).elements
        #expect(elements.count == 1)
        let channel = try #require(elements.first)
        #expect(channel.label == "Workshop")
        let spoken = switch attention {
        case .unread: "Unread messages"
        case .waiting: "Waiting for your response"
        case .finished: "All tasks completed"
        }
        #expect(channel.value.contains(spoken))
    }
    #endif

    private func row(attention: ChannelAttention?) -> some View {
        ChannelSidebarRow(
            channel: Channel(id: "workshop", name: "Workshop", directory: "/Projects/Workshop",
                             model: .init(provider: "test", name: "test"),
                             updatedAt: "2026-10-26T12:00:00Z"),
            agents: [], working: [], attention: attention,
            now: Date(timeIntervalSince1970: 1_793_016_000))
    }

    private func render(attention: ChannelAttention?, scheme: ColorScheme, selected: Bool) throws -> CGImage {
        let renderer = ImageRenderer(content: row(attention: attention)
            .frame(width: 360)
            .background(selected ? Color.blue : (scheme == .dark ? Color.black : Color.white))
            .environment(\.colorScheme, scheme)
            .environment(\.backgroundProminence, selected ? .increased : .standard)
            .dynamicTypeSize(.large))
        renderer.scale = 3
        return try #require(renderer.uiImage?.cgImage)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(
                data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}

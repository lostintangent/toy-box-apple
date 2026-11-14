import ToyBoxKit
import Testing

struct ChannelNavigationTests {
    private struct Move: Sendable, CustomTestStringConvertible {
        let ids: [String]
        let selection: String?
        let direction: ChannelNavigation.Direction
        let target: String?

        init(_ ids: [String], from selection: String?, _ direction: ChannelNavigation.Direction, to target: String?) {
            self.ids = ids
            self.selection = selection
            self.direction = direction
            self.target = target
        }

        var testDescription: String { "\(direction) from \(selection ?? "no selection") in \(ids)" }
    }

    private struct AttentionMove: Sendable, CustomTestStringConvertible {
        let ids: [String]
        let selection: String?
        let attention: Set<String>
        let target: String?

        init(_ ids: [String], from selection: String?, marked attention: Set<String>, to target: String?) {
            self.ids = ids
            self.selection = selection
            self.attention = attention
            self.target = target
        }

        var testDescription: String {
            "from \(selection ?? "no selection") in \(ids), marking \(attention.sorted())"
        }
    }

    @Test(arguments: [
        Move(["third", "first", "second"], from: "third", .next, to: "first"),
        Move(["third", "first", "second"], from: "second", .next, to: "third"),
        Move(["third", "first", "second"], from: "first", .previous, to: "third"),
        Move(["third", "first", "second"], from: "third", .previous, to: "second"),
        Move(["third", "first", "second"], from: nil, .next, to: "third"),
        Move(["third", "first", "second"], from: "missing", .next, to: "third"),
        Move(["third", "first", "second"], from: nil, .previous, to: "second"),
        Move(["third", "first", "second"], from: "missing", .previous, to: "second"),
        Move(["only"], from: "only", .next, to: "only"),
        Move(["only"], from: "only", .previous, to: "only"),
        Move([], from: "missing", .next, to: nil),
        Move([], from: "missing", .previous, to: nil),
    ])
    private func adjacentSelectionWrapsInCatalogOrderAndStartsAtAnEndWithoutOne(_ move: Move) {
        #expect(ChannelNavigation.adjacent(in: move.ids, from: move.selection, direction: move.direction) == move.target)
    }

    @Test(arguments: [
        AttentionMove(["third", "first", "second", "fourth"], from: "third",
                      marked: ["third", "second", "outside-the-catalog"], to: "second"),
        AttentionMove(["third", "first", "second", "fourth"], from: "second",
                      marked: ["third", "second", "outside-the-catalog"], to: "third"),
        AttentionMove(["third", "first", "second", "fourth"], from: "fourth",
                      marked: ["third", "second", "outside-the-catalog"], to: "third"),
        AttentionMove(["third", "first", "second", "fourth"], from: "third", marked: [], to: nil),
        AttentionMove(["third", "first", "second", "fourth"], from: nil, marked: ["outside-the-catalog"], to: nil),
        AttentionMove(["third", "first", "second"], from: nil, marked: ["first", "second"], to: "first"),
        AttentionMove(["third", "first", "second"], from: "missing", marked: ["first", "second"], to: "first"),
        AttentionMove(["first", "second"], from: "first", marked: ["first"], to: "first"),
        AttentionMove(["only"], from: "only", marked: ["only"], to: "only"),
        AttentionMove([], from: "missing", marked: ["missing"], to: nil),
    ])
    private func nextAttentionSkipsUnmarkedChannelsAndWrapsWithoutReordering(_ move: AttentionMove) {
        #expect(ChannelNavigation.nextAttention(in: move.ids, from: move.selection, attentionIDs: move.attention)
                == move.target)
    }
}

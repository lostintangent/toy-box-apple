import ChannelKit
import Testing

struct ChannelNavigationTests {
    @Test func adjacentSelectionRetainsCatalogOrderAndWrapsInBothDirections() {
        let ids = ["third", "first", "second"]
        #expect(ChannelNavigation.adjacent(in: ids, from: "third", direction: .next) == "first")
        #expect(ChannelNavigation.adjacent(in: ids, from: "second", direction: .next) == "third")
        #expect(ChannelNavigation.adjacent(in: ids, from: "first", direction: .previous) == "third")
        #expect(ChannelNavigation.adjacent(in: ids, from: "third", direction: .previous) == "second")
    }

    @Test func missingSelectionsStartAtTheFirstOrLastChannel() {
        let ids = ["third", "first", "second"]
        for selection in [nil, "missing"] {
            #expect(ChannelNavigation.adjacent(in: ids, from: selection, direction: .next) == "third")
            #expect(ChannelNavigation.adjacent(in: ids, from: selection, direction: .previous) == "second")
            #expect(ChannelNavigation.nextAttention(in: ids, from: selection,
                                                    attentionIDs: ["first", "second"]) == "first")
        }
    }

    @Test func attentionSelectionSkipsUnmarkedIDsAndWrapsWithoutReordering() {
        let ids = ["third", "first", "second", "fourth"]
        let attention: Set<String> = ["third", "second", "outside-the-catalog"]
        #expect(ChannelNavigation.nextAttention(in: ids, from: "third", attentionIDs: attention) == "second")
        #expect(ChannelNavigation.nextAttention(in: ids, from: "second", attentionIDs: attention) == "third")
        #expect(ChannelNavigation.nextAttention(in: ids, from: "fourth", attentionIDs: attention) == "third")
        #expect(ChannelNavigation.nextAttention(in: ids, from: "third", attentionIDs: []) == nil)
        #expect(ChannelNavigation.nextAttention(in: ids, from: nil,
                                                attentionIDs: ["outside-the-catalog"]) == nil)
    }

    @Test func aFullCycleCanReturnTheCurrentChannelAndSingletonsStaySelected() {
        #expect(ChannelNavigation.nextAttention(in: ["first", "second"], from: "first",
                                                attentionIDs: ["first"]) == "first")
        for direction in [ChannelNavigation.Direction.next, .previous] {
            #expect(ChannelNavigation.adjacent(in: ["only"], from: "only", direction: direction) == "only")
        }
        #expect(ChannelNavigation.nextAttention(in: ["only"], from: "only",
                                                attentionIDs: ["only"]) == "only")
    }

    @Test func anEmptyCatalogHasNoNavigationTarget() {
        for direction in [ChannelNavigation.Direction.next, .previous] {
            #expect(ChannelNavigation.adjacent(in: [], from: "missing", direction: direction) == nil)
        }
        #expect(ChannelNavigation.nextAttention(in: [], from: "missing",
                                                attentionIDs: ["missing"]) == nil)
    }
}

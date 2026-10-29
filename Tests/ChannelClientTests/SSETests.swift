import Foundation
import Testing
@testable import ChannelClient

struct SSETests {
    @Test func eventFraming() throws {
        let text = "\u{FEFF}: heartbeat\r\nid: 0\r\nevent: channel\r\ndata: first\r\ndata: second\r\nretry: 1200\r\n\r\n"
            + ": heartbeat\n\ndata: third\n\n"
        var decoder = SSEDecoder()
        let frames = try text.utf8.compactMap { try decoder.consume($0) }
        #expect(frames == ["first\nsecond", "third"])
    }

    @Test func bareCarriageReturnsAndEmptyData() throws {
        var decoder = SSEDecoder()
        let frames = try "data:\r\rdata: ✓\r\r".utf8.compactMap { try decoder.consume($0) }
        #expect(frames == ["", "✓"])
    }

    @Test func frameSizeIsBounded() {
        var decoder = SSEDecoder(maximumEventBytes: 12)
        #expect(throws: (any Error).self) {
            for byte in "data: this is too large\n\n".utf8 { _ = try decoder.consume(byte) }
        }
    }

    @Test func prefixAndRevisionZero() throws {
        let api = try ChannelAPI(serverURL: "http://localhost:3210/toybox/")
        #expect(api.endpoint(["api", "v1", "channels", "a/b"]).absoluteString
                == "http://localhost:3210/toybox/api/v1/channels/a%2Fb")
        #expect(api.resourceURL("/api/serve/machine/hello%20world.md")?.absoluteString
                == "http://localhost:3210/toybox/api/serve/machine/hello%20world.md")
        #expect(api.resourceURL("javascript:alert(1)") == nil)
        #expect(api.resourceURL("//untrusted.example/file") == nil)
        let request = api.streamRequest(channelId: "test", after: 0)
        #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "0")
        #expect(request.url?.query == "after=0")
        #expect(api.streamRequest(channelId: "test", after: nil).url?.query == nil)
    }

    @Test func patchDistinguishesOmittedFromNull() throws {
        let encoder = JSONEncoder()
        let omitted = try JSONSerialization.jsonObject(with: encoder.encode(EditChannelInput(name: "New"))) as? [String: Any]
        let cleared = try JSONSerialization.jsonObject(with: encoder.encode(EditChannelInput(purpose: .clear))) as? [String: Any]
        #expect(omitted?["purpose"] == nil)
        #expect(cleared?["purpose"] is NSNull)
    }

    @Test func boundedBackoff() {
        let policy = ReconnectPolicy()
        #expect((0...7).map { policy.delay(attempt: $0) } == [0.5, 1, 2, 4, 8, 15, 15, 15])
    }
}

import CoreGraphics
import Foundation
import Network
import Observation
import Synchronization
import Testing
@testable import ChannelClient
@testable import ChannelKit

@Suite(.timeLimit(.minutes(1)))
struct ScreenConnectionTests {
    @Test func aScreenConnectsUntilItsFirstFrameIsDrawn() {
        var state = ScreenConnection.State()
        #expect(state.phase == .connecting)
        state.receive(.state(title: "Safari", status: .live))
        #expect(state.phase == .connecting && state.title == "Safari")
        state.hasPicture = true
        #expect(state.phase == .live)
    }

    @MainActor @Test func framesAfterTheFirstRedrawOnlyThePicture() throws {
        let connection = try ScreenConnection(api: ChannelAPI(serverURL: "http://127.0.0.1:1"), screenID: "window:1")
        let stateChanges = Mutex(0), pictureChanges = Mutex(0)
        func observe() {
            withObservationTracking { _ = connection.state } onChange: { stateChanges.withLock { $0 += 1 } }
            withObservationTracking { _ = connection.picture } onChange: { pictureChanges.withLock { $0 += 1 } }
        }
        observe()
        try connection.show(frame(), image: image())
        #expect(connection.state.phase == .live)
        #expect(stateChanges.withLock { $0 } == 1 && pictureChanges.withLock { $0 } == 1)

        let next = image()
        observe()
        try connection.show(frame(), image: next)
        #expect(connection.picture.image === next)
        #expect(stateChanges.withLock { $0 } == 1 && pictureChanges.withLock { $0 } == 2)
    }

    @Test func theServerPausesAndEndsAScreen() {
        var state = ScreenConnection.State()
        state.hasPicture = true
        state.receive(.state(status: .paused, reason: "The display is asleep."))
        #expect(state.phase == .paused && state.reason == "The display is asleep.")
        state.receive(.state(status: .live))
        #expect(state.phase == .live && state.reason == nil)
        state.receive(.state(status: .ended, reason: "The window closed."))
        #expect(state.phase == .ended)
    }

    @Test func aLostScreenReconnectsWithBackoffUntilTheServerAnswers() {
        var state = ScreenConnection.State()
        state.hasPicture = true
        #expect(state.lose() == .milliseconds(250))
        #expect(state.phase == .connecting)
        #expect([state.lose(), state.lose(), state.lose(), state.lose(), state.lose()]
                == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(4)])
        state.receive(.state(status: .live))
        #expect(state.lose() == .milliseconds(250))
    }

    @Test func anEndedScreenStaysClosed() {
        var state = ScreenConnection.State()
        state.hasPicture = true
        state.receive(.state(status: .ended, reason: "The window closed."))
        #expect(state.lose() == nil)
        #expect(state.phase == .ended && state.reason == "The window closed." && !state.hasPicture)
    }

    @Test func controlFollowsTheServerAndEndsWithTheSocket() {
        var state = ScreenConnection.State()
        state.receive(.state(status: .live, hasControl: true))
        #expect(state.hasControl)
        state.receive(.error("Take control before sending screen input."))
        #expect(state.hasControl && state.status == .live)
        state.receive(.state(status: .paused))
        #expect(!state.hasControl)
        state.receive(.state(status: .live, hasControl: true))
        _ = state.lose()
        #expect(!state.hasControl)
    }

    @MainActor @Test func aViewerTakesControlSendsInputAndLetsGoOnAnError() async throws {
        let server = try await ScreenSocketServer.start()
        defer { server.stop() }
        var received = server.received.makeAsyncIterator()
        let connection = try ScreenConnection(api: ChannelAPI(serverURL: "http://127.0.0.1:\(server.port)"),
                                              screenID: "window:1")
        connection.viewerSize = CGSize(width: 100, height: 100)
        server.send(#"{"type":"state","title":"Demo Canvas","status":"live","hasControl":false}"#)
        try await eventually { connection.state.status == .live }

        // Without control, input is dropped and release says nothing, so the take arrives first.
        connection.send([.text("dropped")])
        connection.releaseControl()
        connection.takeControl()
        #expect(try await json(received.next()) == ["type": "take-control"] as NSDictionary)
        server.send(#"{"type":"state","title":"Demo Canvas","status":"live","hasControl":true}"#)
        try await eventually { connection.state.hasControl }

        connection.send([.pointer(.down, at: CGPoint(x: 0.5, y: 0.25)), .text("hi")])
        #expect(try await json(received.next()) == ["type": "input", "actions": [
            ["type": "pointer", "x": 0.5, "y": 0.25, "phase": "down", "button": 0],
            ["type": "text", "text": "hi"],
        ]] as NSDictionary)

        // An error in control lets go of the host, and nothing more.
        server.send(#"{"type":"error","message":"The source app lost focus. Take control again before sending input."}"#)
        try await eventually { !connection.state.hasControl }
        #expect(try await json(received.next()) == ["type": "release-control"] as NSDictionary)
        #expect(connection.state.phase == .connecting && connection.state.title == "Demo Canvas")
        connection.viewerSize = nil
    }

    private func json(_ text: String?) throws -> NSDictionary {
        let text = try #require(text)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    private func frame() throws -> Screen.Frame {
        try JSONDecoder().decode(Screen.Frame.self, from: Data(#"{"sequence":1,"width":4,"height":3}"#.utf8))
    }

    private func image() -> CGImage {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}

/// A loopback WebSocket server that plays the screens socket's server side for one viewer. It sends
/// text once a viewer connects, and yields the text the viewer sends.
private final class ScreenSocketServer: @unchecked Sendable {
    let port: UInt16
    let received: AsyncStream<String>
    private let listener: NWListener
    private let queue: DispatchQueue
    private let continuation: AsyncStream<String>.Continuation
    /// Guarded by `queue`.
    private var viewer: NWConnection?
    private var pending: [String] = []

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue) {
        (self.listener, self.port, self.queue) = (listener, port, queue)
        (received, continuation) = AsyncStream.makeStream()
    }

    static func start() async throws -> ScreenSocketServer {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "ScreenSocketServer")
        let port = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let server = ScreenSocketServer(listener: listener, port: port, queue: queue)
        listener.newConnectionHandler = { [server] connection in server.accept(connection) }
        return server
    }

    func send(_ text: String) {
        queue.async { [self] in
            if let viewer { write(text, to: viewer) } else { pending.append(text) }
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in viewer?.cancel() }
        continuation.finish()
    }

    private func accept(_ connection: NWConnection) {
        viewer = connection
        connection.start(queue: queue)
        receive(on: connection)
        for text in pending { write(text, to: connection) }
        pending = []
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] content, _, _, error in
            if let content { continuation.yield(String(decoding: content, as: UTF8.self)) }
            if error == nil { receive(on: connection) }
        }
    }

    private func write(_ text: String, to connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "text",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, completion: .idempotent)
    }
}

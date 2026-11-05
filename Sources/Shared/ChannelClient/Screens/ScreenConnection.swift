import ChannelKit
import CoreGraphics
import Foundation
import ImageIO
import Observation

/// One viewer's live view of a screen. The socket is open only while the viewer is on screen, and it
/// reconnects until the screen ends. Frames decode off the main actor in order, and each is
/// acknowledged once it's published. Its tasks hold it weakly, so deinit closes only the socket.
@MainActor @Observable
public final class ScreenConnection {
    /// Connecting until the first frame is drawn, then live, unless the server says otherwise.
    public enum Phase: Equatable, Sendable { case connecting, live, paused, ended }

    public struct State: Sendable {
        /// What the server last said, unknown until it answers a new socket.
        public private(set) var status: Screen.Status?
        public private(set) var title: String?
        public private(set) var reason: String?
        var hasPicture = false
        /// A lost socket reconnects after 250 ms, doubling up to 4 s until the server answers.
        private(set) var retryDelay = firstRetry

        static let firstRetry = Duration.milliseconds(250)
        static let lastRetry = Duration.seconds(4)

        public var phase: Phase {
            switch status {
            case .paused: .paused
            case .ended: .ended
            case .live, nil: hasPicture ? .live : .connecting
            }
        }

        mutating func receive(_ message: Screen.Message) {
            (title, status, reason) = (message.title, message.status, message.reason)
            retryDelay = Self.firstRetry
        }

        /// Clears what a lost socket showed, and returns how long to wait before reconnecting. A
        /// screen that ended said so before its socket closed, so it stays closed.
        mutating func lose() -> Duration? {
            hasPicture = false
            guard status != .ended else { return nil }
            status = nil
            defer { retryDelay = min(retryDelay * 2, Self.lastRetry) }
            return retryDelay
        }
    }

    public let screenID: String
    public private(set) var state = State()
    /// Apart from `state`, which only a socket's first frame changes, so a frame redraws only this.
    public private(set) var picture = Screen.Picture()

    /// The viewer's size in pixels while it's on screen, which opens the socket, and nil once it hides,
    /// which closes it. A change in between is sent once it settles.
    @ObservationIgnored public var viewerSize: CGSize? {
        didSet {
            guard viewerSize != oldValue else { return }
            if viewerSize == nil { close() } else if oldValue == nil { open() } else { resize() }
        }
    }

    @ObservationIgnored private let api: ChannelAPI
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// Receives from the open socket, or waits to reconnect.
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var settling: Task<Void, Never>?

    public init(api: ChannelAPI, screenID: String) {
        self.api = api
        self.screenID = screenID
    }

    deinit { socket?.cancel(with: .goingAway, reason: nil) }

    /// Connects again, which reopens a screen that ended.
    public func retry() {
        close()
        open()
    }

    /// Sends the settled size to an open socket. A reconnecting viewer opens at its latest size.
    private func resize() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let socket = self?.socket, let size = self?.viewerSize else { return }
            let (width, height) = (Int(size.width.rounded()), Int(size.height.rounded()))
            let message = #"{"type":"resize","size":{"width":\#(width),"height":\#(height)}}"#
            try? await socket.send(.string(message))
        }
    }

    private func open() {
        guard let size = viewerSize else { return }
        let socket = api.screenSocket(id: screenID, size: size)
        self.socket = socket
        socket.resume()
        work = Task { [weak self] in
            do {
                while true {
                    let message = try await socket.receive()
                    guard let self, self.socket === socket else { return }
                    try await self.receive(message, on: socket)
                }
            } catch {
                self?.lose(socket)
            }
        }
    }

    private func receive(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask) async throws {
        switch message {
        case .string(let text):
            if let message = try? JSONDecoder().decode(Screen.Message.self, from: Data(text.utf8)) {
                state.receive(message)
            }
        case .data(let packet):
            let (frame, image) = try await Task.detached(priority: .userInitiated) { try Self.decode(packet) }.value
            guard self.socket === socket else { return }
            try show(frame, image: image)
            try await socket.send(.string(#"{"type":"ack","sequence":\#(frame.sequence)}"#))
        @unknown default: break
        }
    }

    func show(_ frame: Screen.Frame, image: CGImage?) throws {
        try picture.apply(frame, image: image)
        if !state.hasPicture { state.hasPicture = true }
    }

    private nonisolated static func decode(_ packet: Data) throws -> (Screen.Frame, CGImage?) {
        let (frame, jpeg) = try Screen.Frame.unpack(packet)
        guard !jpeg.isEmpty else { return (frame, nil) }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ChannelAPIError.invalidMessage("A screen frame's image couldn't be decoded.")
        }
        return (frame, image)
    }

    /// A frame that can't be drawn starts over on a new socket, like any other close.
    private func lose(_ socket: URLSessionWebSocketTask) {
        guard self.socket === socket else { return }
        socket.cancel(with: .goingAway, reason: nil)
        (self.socket, picture) = (nil, Screen.Picture())
        guard let delay = state.lose() else { return }
        work = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }

    /// Starts over on the next open. The title stays, since a hidden window still shows it.
    private func close() {
        work?.cancel()
        settling?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        (work, settling, socket) = (nil, nil, nil)
        (state, picture) = (State(title: state.title), Screen.Picture())
    }
}

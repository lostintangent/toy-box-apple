import AppKit
import Foundation
import Network
import SwiftUI
import Synchronization
import Testing
import Thrush
import ToyBoxClient
import ToyBoxTerminal

@MainActor
struct TerminalTests {
    /// A long command keeps its shell past the server's 30 seconds only while the window holds its
    /// socket, so a minimized window still hears its shell, on the socket it opened with.
    @Test func aMinimizedWindowKeepsItsShellsSocket() async throws {
        let server = try await TerminalSocketServer.start()
        defer { server.stop() }
        let suite = "TerminalTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = try ChannelAPI(serverURL: "http://127.0.0.1:\(server.port)")
        let shell = TerminalShells(defaults: defaults).shell(on: api)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TerminalPane(shell))
        window.orderFront(nil)
        defer { window.close() }

        server.send(title: "Shown")
        try await waitUntil("the shell sets its title", in: window.contentView) { shell.title == "Shown" }
        window.miniaturize(nil)
        try await waitUntil("the window minimizes", in: window.contentView) { window.isMiniaturized }
        server.send(title: "Minimized")
        try await waitUntil("the minimized window hears its shell", in: window.contentView) {
            shell.title == "Minimized"
        }
        #expect(server.connections == 1)
    }
}

/// A loopback WebSocket server that plays one shell for the terminal socket. It answers each
/// connection with a fresh shell's ready, then sends the output it's given to the latest one.
private final class TerminalSocketServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private let accepted = Mutex(0)
    /// Guarded by `queue`.
    private var shell: NWConnection?
    private var pending: [Data] = []

    var connections: Int { accepted.withLock { $0 } }

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue) {
        (self.listener, self.port, self.queue) = (listener, port, queue)
    }

    static func start() async throws -> TerminalSocketServer {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "TerminalSocketServer")
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
        let server = TerminalSocketServer(listener: listener, port: port, queue: queue)
        listener.newConnectionHandler = { [server] connection in server.accept(connection) }
        return server
    }

    /// Sends the escape sequence a shell uses to set the window title.
    func send(title: String) {
        let output = Data("\u{1B}]2;\(title)\u{07}".utf8)
        queue.async { [self] in
            if let shell { write(output, as: .binary, to: shell) } else { pending.append(output) }
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in shell?.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        accepted.withLock { $0 += 1 }
        shell = connection
        connection.start(queue: queue)
        receive(on: connection)
        write(Data(#"{"type":"ready","resumed":false}"#.utf8), as: .text, to: connection)
        for output in pending { write(output, as: .binary, to: connection) }
        pending = []
    }

    /// Reads and drops what the pane sends, its size and keys.
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] _, _, _, error in
            if error == nil { receive(on: connection) }
        }
    }

    private func write(_ data: Data, as opcode: NWProtocolWebSocket.Opcode, to connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "message",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: data, contentContext: context, completion: .idempotent)
    }
}

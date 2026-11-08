import Foundation
import os
import Synchronization

extension ChannelOutbox {
    /// Hands the phone's sends to iOS as background uploads, so they finish after Toy Box stops
    /// running. Each process needs its own session, and an extension's identifier starts with its
    /// app's, so the app can take the events iOS relaunches it for.
    public struct Background: Sendable {
        public var session: String
        /// The app group an extension shares with its app, so the app can finish its uploads.
        public var sharedContainer: String?
        /// Every send goes to iOS at once, for an extension that ends before it could finish one.
        public var handsOff: Bool

        public init(session: String, sharedContainer: String? = nil, handsOff: Bool = false) {
            self.session = session
            self.sharedContainer = sharedContainer
            self.handsOff = handsOff
        }
    }

    /// What iOS reports, in the order it arrives.
    enum Upload: Sendable {
        /// An upload ended, with the server's answer or the error that stopped it.
        case finished(UUID, HTTPURLResponse?, Data, (any Error)?)
        /// A session reported everything it had for the app, so the app may suspend.
        case delivered(session: String)
    }

    /// The uploads iOS runs for the outbox. Tests pass one they finish themselves.
    protocol Uploads: Sendable {
        /// This process's own session.
        var session: String { get }
        var events: AsyncStream<Upload> { get }
        /// Saves the request's body and starts its upload. A failure reports as the upload finishing.
        func start(_ request: URLRequest, id: UUID)
        /// Reconnects to a session iOS has events for, its own or the share extension's.
        func open(_ session: String)
    }
}

/// A background `URLSession` per identifier, with each body saved beside the outbox until its upload
/// ends. A session opens on its first upload, or when iOS has events for it.
final class BackgroundUploads: NSObject, ChannelOutbox.Uploads, URLSessionDataDelegate {
    let events: AsyncStream<ChannelOutbox.Upload>
    private let continuation: AsyncStream<ChannelOutbox.Upload>.Continuation
    private let background: ChannelOutbox.Background
    private let bodies: URL
    private let state = Mutex(State())

    private struct State {
        var sessions: [String: URLSession] = [:]
        var received: [Received: Data] = [:]
    }

    private struct Received: Hashable {
        let session: String
        let task: Int
    }

    init(_ background: ChannelOutbox.Background, folder: URL) {
        self.background = background
        bodies = folder.appending(path: "Uploads", directoryHint: .isDirectory)
        (events, continuation) = AsyncStream.makeStream()
    }

    var session: String { background.session }

    func start(_ request: URLRequest, id: UUID) {
        let file = body(id, in: background.session)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // iOS reads it while the phone is locked, as for a Lock Screen reply.
            try (request.httpBody ?? Data()).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            continuation.yield(.finished(id, nil, Data(), error))
            return
        }
        var upload = request
        upload.httpBody = nil
        let task = session(background.session).uploadTask(with: upload, fromFile: file)
        task.taskDescription = id.uuidString
        task.resume()
    }

    func open(_ session: String) { _ = self.session(session) }

    private func session(_ identifier: String) -> URLSession {
        state.withLock { state in
            if let session = state.sessions[identifier] { return session }
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sharedContainerIdentifier = background.sharedContainer
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            state.sessions[identifier] = session
            return session
        }
    }

    private func body(_ id: UUID, in session: String) -> URL {
        bodies.appending(path: session, directoryHint: .isDirectory).appending(path: id.uuidString)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = Received(session: session.configuration.identifier ?? "", task: dataTask.taskIdentifier)
        state.withLock { $0.received[key, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let identifier = session.configuration.identifier ?? ""
        let data = state.withLock {
            $0.received.removeValue(forKey: Received(session: identifier, task: task.taskIdentifier))
        } ?? Data()
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        do { try FileManager.default.removeItem(at: body(id, in: identifier)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
        catch { Self.logger.error("Could not remove an upload's body: \(error.localizedDescription)") }
        continuation.yield(.finished(id, task.response as? HTTPURLResponse, data, error))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.delivered(session: session.configuration.identifier ?? ""))
    }

    private static let logger = Logger(subsystem: "dev.toybox", category: "Outbox")
}

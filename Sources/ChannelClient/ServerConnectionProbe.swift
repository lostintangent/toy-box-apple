import ChannelKit
import Foundation
import Observation

public func isLoopbackHost(_ host: String) -> Bool {
    host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
}

@MainActor @Observable
public final class ServerConnectionProbe {
    public enum Phase {
        case idle
        case testing(URL)
        case connected(URL, channelCount: Int)
        case failed(address: String, error: any Error)
    }

    public var address: String {
        didSet {
            if oldValue != address { cancel() }
        }
    }
    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let loadCatalog: @Sendable (ChannelAPI) async throws -> ChannelCatalog
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?

    public convenience init(address: String = "", session: URLSession = .shared) {
        self.init(address: address, session: session, loadCatalog: { try await $0.catalog() })
    }

    init(address: String, session: URLSession = .shared,
         loadCatalog: @escaping @Sendable (ChannelAPI) async throws -> ChannelCatalog) {
        self.address = address
        self.session = session
        self.loadCatalog = loadCatalog
    }

    deinit { work?.cancel() }

    public var isTesting: Bool {
        if case .testing = phase { return true }
        return false
    }

    public var validationError: String? {
        do {
            _ = try ChannelAPI(serverURL: address, session: session)
            return nil
        } catch { return error.localizedDescription }
    }

    @discardableResult
    public func start() -> Task<Void, Never>? {
        cancel()
        let api: ChannelAPI
        do { api = try ChannelAPI(serverURL: address, session: session) }
        catch {
            phase = .failed(address: address, error: error)
            return nil
        }
        let input = address
        let token = generation
        let loadCatalog = loadCatalog
        phase = .testing(api.baseURL)
        let operation = Task { [weak self] in
            do {
                let catalog = try await loadCatalog(api)
                guard let self, self.generation == token, self.address == input else { return }
                self.work = nil
                self.phase = Task.isCancelled ? .idle : .connected(api.baseURL, channelCount: catalog.channels.count)
            } catch {
                guard let self, self.generation == token, self.address == input else { return }
                self.work = nil
                self.phase = Task.isCancelled ? .idle : .failed(address: input, error: error)
            }
        }
        work = operation
        return operation
    }

    public func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
        phase = .idle
    }
}

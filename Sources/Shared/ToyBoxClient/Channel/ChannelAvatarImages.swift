import ToyBoxKit
import CoreGraphics
import Foundation
import Synchronization

/// Channel avatar images, each fetched and decoded once per URL while the app runs. The server names
/// a stored image by its content, so a URL always shows the same image, and a new image arrives
/// under a new URL.
public final class ChannelAvatarImages: Sendable {
    public static let shared = ChannelAvatarImages()

    public enum Image: Sendable {
        case loaded(CGImage)
        /// The server refused it, or the platform can't decode it, so the channel shows its # until
        /// its avatar's URL changes.
        case failed
    }

    /// The longest side kept, which covers the largest frame, 60 points at 3x.
    static let maxPixelSize = 180

    private struct State {
        var images: [URL: Image] = [:]
        var loads: [URL: Task<Image, Never>] = [:]
    }

    private let state = Mutex(State())

    init() {}

    /// What an earlier load found, so a frame drawn again shows it at once.
    public func image(_ address: String, api: ChannelAPI) -> Image? {
        guard let url = api.resourceURL(address) else { return .failed }
        return state.withLock { $0.images[url] }
    }

    /// Fetches and decodes an image once, however many frames ask for it together. A connection
    /// that fails isn't remembered, so the next frame to ask tries again.
    @discardableResult
    public func load(_ address: String, api: ChannelAPI) async -> Image {
        guard let url = api.resourceURL(address) else { return .failed }
        let next = state.withLock { state -> Next in
            if let image = state.images[url] { return .known(image) }
            if let task = state.loads[url] { return .loading(task) }
            let task = Task {
                let (image, remembered) = await Self.fetch(url, session: api.session)
                self.state.withLock { state in
                    if remembered { state.images[url] = image }
                    state.loads[url] = nil
                }
                return image
            }
            state.loads[url] = task
            return .loading(task)
        }
        switch next {
        case .known(let image): return image
        case .loading(let task): return await task.value
        }
    }

    private enum Next {
        case known(Image)
        case loading(Task<Image, Never>)
    }

    private static func fetch(_ url: URL, session: URLSession) async -> (image: Image, remembered: Bool) {
        // The URL names the content, so a cached copy is never stale.
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, response) = try? await session.data(for: request) else { return (.failed, false) }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let image = ChannelImageDecoder.thumbnail(data: data, maxPixelSize: maxPixelSize) else {
            return (.failed, true)
        }
        return (.loaded(image), true)
    }
}

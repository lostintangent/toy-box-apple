import AppKit
import ChannelClient
import ChannelKit
import Observation
import QuickLook
import SwiftUI

@MainActor @Observable
final class ArtifactOpener {
    var artifact: ChannelArtifact?
    func open(_ artifact: ChannelArtifact) { self.artifact = artifact }
}

extension View {
    func artifactReaders(_ opener: ArtifactOpener, channelId: String? = nil) -> some View {
        modifier(ArtifactReadersModifier(opener: opener, channelId: channelId))
    }
}

private struct ArtifactReadersModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var opener: ArtifactOpener
    let channelId: String?

    func body(content: Content) -> some View {
        content.sheet(item: $opener.artifact) { artifact in
            if let api = app.api {
                ArtifactReader(artifact: artifact, api: api, channelId: channelId)
            } else {
                ContentUnavailableView("Server Unavailable", systemImage: "wifi.exclamationmark",
                                       description: Text("Configure the Toy Box server in Settings."))
            }
        }
    }
}

struct ArtifactReader: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let artifact: ChannelArtifact
    let api: ChannelAPI
    var channelId: String?
    @ViewState private var content: String?
    @ViewState private var isLoading = false
    @ViewState private var error: String?
    @ViewState private var attempt = 0
    @ViewState private var localFile: URL?
    @ViewState private var previewFile: URL?

    private var isMarkdown: Bool {
        ["md", "markdown", "mdown"].contains((artifact.file.path as NSString).pathExtension.lowercased())
    }
    private var resource: URL? { artifact.url.flatMap(api.resourceURL) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(artifact.title).font(.headline)
                    Text(artifact.file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            Group {
                if isLoading {
                    ProgressView("Loading artifact").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't Open Artifact", systemImage: "doc.badge.ellipsis")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { attempt += 1 }
                    }
                } else if let content {
                    ScrollView {
                        TranscriptMarkdown(content: content, agents: [], baseURL: resource)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                } else if let localFile {
                    ContentUnavailableView {
                        Label(artifact.title, systemImage: "doc")
                    } description: {
                        Text("Preview this file without leaving the channel, or open it in its default application.")
                    } actions: {
                        Button("Quick Look", systemImage: "eye") { previewFile = localFile }
                        Button("Open File") {
                            if !NSWorkspace.shared.open(localFile) {
                                error = "The file could not be opened by its default application."
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Artifact Unavailable", systemImage: "doc.badge.ellipsis")
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button("Open in Toy Box") { openInToyBox() }
                if let resource {
                    ShareLink(item: resource) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resource.absoluteString, forType: .string)
                    }
                }
                Spacer()
                if content != nil || localFile != nil {
                    Button("Reload", systemImage: "arrow.clockwise") { attempt += 1 }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 480, idealWidth: 680, maxWidth: 820,
               minHeight: 360, idealHeight: 560, maxHeight: 760)
        .quickLookPreview($previewFile)
        .task(id: attempt) { await load() }
    }

    private func load() async {
        content = nil
        error = nil
        guard let resource else {
            error = "The server did not provide a usable resource URL for this artifact."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            if isMarkdown {
                let text = try await ArtifactDownload.text(from: resource)
                guard !Task.isCancelled else { return }
                content = text
            } else {
                let file = try await ArtifactDownload.file(for: artifact, from: resource)
                guard !Task.isCancelled else { return }
                localFile = file
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func openInToyBox() {
        guard let id = channelId ?? app.activeChannelID,
              let url = app.channelURL(channelID: id, files: [artifact.file]) else {
            error = "The channel's Toy Box editor link is unavailable."
            return
        }
        if !NSWorkspace.shared.open(url) { error = "The Toy Box editor could not be opened." }
    }
}

/// Fetches artifact content from the server's resource URL, never assuming the file is local.
enum ArtifactDownload {
    static func text(from resource: URL) async throws -> String {
        let request = URLRequest(url: resource, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChannelAPIError.invalidMessage("This Markdown artifact is not valid UTF-8 text.")
        }
        return text
    }

    /// Downloads into a private temporary folder under the artifact's own file name.
    static func file(for artifact: ChannelArtifact, from resource: URL) async throws -> URL {
        let request = URLRequest(url: resource, cachePolicy: .reloadIgnoringLocalCacheData)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try validate(response)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToyBoxChannels-Artifacts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = (artifact.file.path as NSString).lastPathComponent
        let destination = directory.appendingPathComponent(
            ["", ".", "..", "/"].contains(basename) ? "Artifact" : basename)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ChannelAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ChannelAPIError.http(status: http.statusCode, message: "The artifact could not be loaded.")
        }
    }
}

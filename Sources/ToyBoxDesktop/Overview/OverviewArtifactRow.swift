import AppKit
import ChannelClient
import ChannelKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A shared file: its real Finder icon, the title, and who shared it and when.
struct OverviewArtifactRow: View {
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(\.channelTextScale) private var textScale
    let artifact: ChannelArtifact
    let share: ChannelArtifactShare?
    let agents: [ChannelAgent]
    let api: ChannelAPI
    let open: () -> Void
    @ViewState private var previewFile: URL?
    @ViewState private var isFetching = false
    @ViewState private var error: String?

    private var resource: URL? { artifact.url.flatMap(api.resourceURL) }
    private var type: UTType? {
        let pathExtension = (artifact.file.path as NSString).pathExtension
        return pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension)
    }
    private var sharedDate: Date? { (share?.sharedAt ?? artifact.sharedAt).flatMap(ChannelDates.date) }

    /// The sharer from the latest loaded share event, or the localized file type when it is not loaded.
    private var source: String {
        if let actor = share?.actor {
            switch actor.type {
            case "user": return "You"
            case "agent": if let id = actor.agentId { return channelAgentIdentity(agents, id: id).name }
            default: break
            }
        }
        return type?.localizedDescription ?? "Document"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(for: type ?? .data))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(artifact.title)
                            .font(.system(size: 13 * textScale))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        TimelineView(.everyMinute) { context in
                            Text(subtitle(now: context.date))
                                .font(.system(size: 11 * textScale))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if isFetching {
                        ProgressView().controlSize(.mini).accessibilityLabel("Preparing Quick Look")
                    }
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .onKeyPress(.space) {
                quickLook()
                return .handled
            }
            .onKeyPress(.return) {
                open()
                return .handled
            }
            .accessibilityLabel(artifact.title)
            .accessibilityValue(subtitle(now: .now))
            .accessibilityActions { actions }
            .contextMenu { actions }
            if let error { ManagementError(message: error).padding(.leading, 38) }
        }
        .quickLookPreview($previewFile)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Open", action: open)
        Button("Quick Look", action: quickLook).disabled(resource == nil || isFetching)
        Button("Show in Transcript") {
            if let sequence = share?.sequence { interaction.reveal(sequence: sequence) }
        }
        .disabled(share == nil)
        Divider()
        Button("Copy Link") {
            guard let resource else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(resource.absoluteString, forType: .string)
        }
        .disabled(resource == nil)
    }

    private func subtitle(now: Date) -> String {
        guard let sharedDate else { return source }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .short
        // The row updates each minute, so anything newer reads "now" rather than a stale seconds count.
        let date = now.timeIntervalSince(sharedDate) < 60 ? now : sharedDate
        return "\(source) · \(formatter.localizedString(for: date, relativeTo: now))"
    }

    private var help: String {
        var lines = [artifact.title, artifact.file.path]
        if let sharedDate { lines.append("Shared \(sharedDate.formatted(date: .complete, time: .shortened))") }
        return lines.joined(separator: "\n")
    }

    private func quickLook() {
        guard !isFetching else { return }
        guard let resource else {
            error = "The server did not provide a usable resource URL for this artifact."
            return
        }
        isFetching = true
        error = nil
        Task {
            defer { isFetching = false }
            do {
                previewFile = try await ArtifactDownload.file(for: artifact, from: resource)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

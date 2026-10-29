import AppKit
import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The channel's property inspector: About, then collapsible Team, Tasks, Artifacts and Routines.
///
/// The channel's detail view re-renders on every event. This view holds nothing but the store, so
/// SwiftUI sees it unchanged and skips it. Property wrappers would make it look new each time,
/// which would rebuild every section and row for each message.
///
/// A window that switches channels updates Overview in place. Its scroll view, section headers and
/// rows stay, and `OverviewSlots` hands each row the new channel's item at its position, because
/// building rows is most of what a switch costs here. Everything that belongs to one channel still
/// starts over: the scroll position, each row's disclosure, popover, Quick Look and run state, and
/// About's purpose expansion and errors. Rows keep that state per item and visit, so it never
/// follows a row to another channel. Collapsed sections belong to the window and stay as they are.
struct OverviewInspector: View {
    let store: ChannelStore

    var body: some View {
        OverviewInspectorContent(store: store)
    }
}

private struct OverviewInspectorContent: View {
    @Environment(ArtifactOpener.self) private var artifacts
    @Environment(\.channelTextScale) private var textScale
    @Environment(\.windowSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("overviewCollapsedSections") private var collapsedSections = ""
    let store: ChannelStore

    private var collapsed: Binding<Set<OverviewSectionID>> {
        Binding(get: { OverviewSectionID.decode(collapsedSections) },
                set: { collapsedSections = OverviewSectionID.encode($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Only `details` and `phase` are read here. Each section reads its own slices, so a new
            // message, a status or a task update re-evaluates just the section that shows it.
            if let details = store.details, store.phase != .deleted {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if store.phase.isUnavailable {
                                Label("Overview may be out of date until the channel connects.",
                                      systemImage: "wifi.exclamationmark")
                                    .font(.system(size: 12 * textScale))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, 10)
                            }
                            OverviewAbout(details: details, store: store)
                                .padding(.bottom, 12)
                            OverviewTeamSection(store: store, collapsed: collapsed)
                            OverviewTasksSection(store: store, collapsed: collapsed, onArtifactOpen: artifacts.open)
                                .id("overview-tasks")
                            OverviewArtifactsSection(store: store, collapsed: collapsed)
                                .id("overview-artifacts")
                            OverviewRoutinesSection(store: store, collapsed: collapsed) { routine in
                                DispatchQueue.main.async {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                        proxy.scrollTo("overview-routine-details-\(routine.id)", anchor: .bottom)
                                    }
                                }
                            }
                            .id("overview-routines")
                        }
                        .padding(.top, Self.contentInsets.top)
                        .padding(.horizontal, Self.contentInsets.leading)
                        .padding(.bottom, Self.contentInsets.bottom)
                        .font(.system(size: 13 * textScale))
                        .id(Self.topID)
                    }
                    // The automatic top edge draws nothing at the top on macOS 27, so rows would run
                    // under the glass controls. A hard edge continues the conversation's divider.
                    .scrollEdgeEffectStyle(.hard, for: .top)
                    .onChange(of: store.id) { proxy.scrollTo(Self.topID, anchor: .top) }
                    .task(id: snapshot?.requestedState) {
                        guard let snapshot, let name = snapshot.requestedState,
                              let section = Self.snapshotSections[name] else { return }
                        collapsed.wrappedValue.remove(section)
                        await Task.yield()
                        proxy.scrollTo(name, anchor: .top)
                        snapshot.markStateReady(name)
                    }
                }
            } else {
                ContentUnavailableView(
                    store.phase == .deleted ? "Channel Deleted" : "Connecting",
                    systemImage: store.phase == .deleted ? "trash" : "bubble.left.and.bubble.right",
                    description: Text(store.phase == .deleted
                                      ? "This channel is no longer available."
                                      : "Overview appears when the channel connects."))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Overview")
    }

    /// Content rests 12pt below the toolbar's safe area and scrolls beneath the glass toolbar.
    static let contentInsets = EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
    private static let topID = "overview-top"

    private static let snapshotSections: [String: OverviewSectionID] = [
        "overview-tasks": .tasks, "overview-artifacts": .artifacts, "overview-routines": .routines,
    ]
}

private struct OverviewTeamSection: View {
    let store: ChannelStore
    @Binding var collapsed: Set<OverviewSectionID>

    var body: some View {
        OverviewSection(id: .team, summary: .team(store.roster.count), collapsed: $collapsed) {
            OverviewTeamList(store: store)
        }
    }
}

private struct OverviewTasksSection: View {
    @Environment(\.channelTextScale) private var textScale
    let store: ChannelStore
    @Binding var collapsed: Set<OverviewSectionID>
    let onArtifactOpen: (ChannelArtifact) -> Void

    var body: some View {
        let tasks = store.tasks
        let progress = channelTasksProgress(tasks)
        let diff = channelTasksDiff(tasks)
        OverviewSection(id: .tasks, summary: .tasks(progress),
                        accessibilityDetail: diff.map(ChannelOverviewTaskDiff.spoken), collapsed: $collapsed) {
            if let diff {
                ChannelOverviewTaskDiff(diff: diff)
                    .font(.system(size: 11 * textScale))
                    .accessibilityHidden(true)
            }
        } content: {
            OverviewTaskList(tasks: tasks, agents: store.roster, artifacts: store.artifacts,
                             channelId: store.id, onArtifactOpen: onArtifactOpen)
        }
    }
}

private struct OverviewArtifactsSection: View {
    @Environment(ArtifactOpener.self) private var opener
    let store: ChannelStore
    @Binding var collapsed: Set<OverviewSectionID>
    @ViewState private var slots = OverviewSlots()

    var body: some View {
        let artifacts = channelArtifactsNewestFirst(store.artifacts)
        OverviewSection(id: .artifacts, summary: .artifacts(artifacts.count), collapsed: $collapsed) {
            if artifacts.isEmpty {
                OverviewEmptyText("Nothing shared yet")
            } else {
                let shares = store.artifactShares
                let agents = store.roster
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slots.entries(artifacts, in: store.id)) { entry in
                        let artifact = entry.item
                        OverviewArtifactRow(artifact: artifact, key: entry.key, share: shares[artifact.file.id],
                                            agents: agents, api: store.api,
                                            open: { opener.open(artifact) })
                    }
                }
            }
        }
    }
}

private struct OverviewRoutinesSection: View {
    let store: ChannelStore
    @Binding var collapsed: Set<OverviewSectionID>
    let revealDetails: (ChannelRoutine) -> Void
    @ViewState private var slots = OverviewSlots()

    var body: some View {
        let routines = store.routines
        OverviewSection(id: .routines, summary: .routines(routines.count), collapsed: $collapsed) {
            if routines.isEmpty {
                OverviewEmptyText("No routines")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slots.entries(routines, in: store.id)) { entry in
                        OverviewRoutineRow(routine: entry.item, key: entry.key, store: store) {
                            revealDetails(entry.item)
                        }
                    }
                }
            }
        }
    }
}

/// The untitled first section: purpose, then compact folder and preview properties.
private struct OverviewAbout: View {
    @Environment(AppModel.self) private var app
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.channelTextScale) private var textScale
    let details: ChannelDetails
    let store: ChannelStore
    @ViewState private var visits = OverviewVisits()

    var body: some View {
        let visit = "\(visits.visit(store.id))"
        VStack(alignment: .leading, spacing: 0) {
            if let purpose = details.purpose, !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                OverviewPurpose(purpose: purpose, visit: visit)
            } else {
                Button("Add a purpose…") { management.present(.editChannel(channelId: store.id)) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13 * textScale))
                    .foregroundStyle(.secondary)
                    .disabled(!store.phase.isConnected)
                    .help(store.phase.isUnavailable ? "Available when the channel connects" : "Edit Channel")
            }
            let preview = details.resolvedPreview
            if details.directory != nil || preview != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if let directory = details.directory, !directory.isEmpty {
                        OverviewFolderRow(
                            directory: directory,
                            availability: app.folderAvailability(path: directory, server: store.api.baseURL),
                            visit: visit,
                            channelURL: { [app, id = store.id] in app.channelURL(channelID: id) })
                    }
                    if let preview {
                        OverviewPreviewRow(preview: preview, api: store.api, channelId: store.id, visit: visit)
                    }
                }
                .padding(.top, 10)
            }
        }
    }
}

/// Up to four lines of purpose with an inline More link that expands in place.
struct OverviewPurpose: View {
    static let lineLimit = 4
    private static let toggleURL = URL(string: "toybox-overview:purpose")!

    @Environment(\.channelTextScale) private var textScale
    let purpose: String
    /// The channel visit the purpose belongs to. See `OverviewVisits`.
    let visit: String
    /// The visit whose purpose is expanded. A switch starts collapsed but keeps the measured width,
    /// so the new purpose truncates in its first pass.
    @ViewState private var expandedVisit: String?
    @ViewState private var availableWidth: CGFloat = 0

    private var expanded: Bool {
        get { expandedVisit == visit }
        nonmutating set { expandedVisit = newValue ? visit : nil }
    }

    var body: some View {
        let fontSize = 13 * textScale
        let truncated = expanded ? nil : Self.truncated(purpose, width: availableWidth, fontSize: fontSize)
        let collapsible = expanded && Self.requiresExpansion(purpose, width: availableWidth, fontSize: fontSize)
        let label = Text(text(truncated: truncated, collapsible: collapsible))
            .font(.system(size: fontSize))
            .lineSpacing(2)
            .lineLimit(expanded ? nil : Self.lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            // Selectable text routes link clicks to its own text view, so a purpose that carries
            // the More or Less link stays plain and offers Copy from its context menu instead.
            if truncated != nil || collapsible {
                label.contextMenu {
                    Button("Copy Purpose") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(purpose, forType: .string)
                    }
                }
            } else {
                label.textSelection(.enabled)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .environment(\.openURL, OpenURLAction { url in
            guard url == Self.toggleURL else { return .systemAction }
            expanded.toggle()
            return .handled
        })
        .accessibilityLabel(purpose)
        .accessibilityActions {
            if truncated != nil || collapsible {
                Button(expanded ? "Show Less" : "Show More") { expanded.toggle() }
            }
        }
    }

    private func text(truncated: String?, collapsible: Bool) -> AttributedString {
        var link: AttributedString
        var text: AttributedString
        if let truncated {
            text = AttributedString(truncated + "… ")
            link = AttributedString("More")
        } else if collapsible {
            text = AttributedString(purpose + " ")
            link = AttributedString("Less")
        } else {
            return AttributedString(purpose)
        }
        link.link = Self.toggleURL
        text.append(link)
        return text
    }

    static func requiresExpansion(_ text: String, width: CGFloat, fontSize: CGFloat) -> Bool {
        guard width > 0, !text.isEmpty else { return false }
        return lineCount(text, width: width, fontSize: fontSize, stoppingAfter: lineLimit) > lineLimit
    }

    /// The longest prefix that still fits in four lines with "… More" after it, or nil when the purpose fits.
    static func truncated(_ text: String, width: CGFloat, fontSize: CGFloat) -> String? {
        guard requiresExpansion(text, width: width, fontSize: fontSize) else { return nil }
        let characters = Array(text)
        func fits(_ count: Int) -> Bool {
            let prefix = String(characters[..<count]).trimmingCharacters(in: .whitespacesAndNewlines)
            return lineCount(prefix + "… More", width: width, fontSize: fontSize, stoppingAfter: lineLimit)
                <= lineLimit
        }
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        var prefix = String(characters[..<low])
        if low < characters.count, !characters[low].isWhitespace,
           let space = prefix.lastIndex(where: \.isWhitespace),
           prefix.distance(from: space, to: prefix.endIndex) < 24 {
            prefix = String(prefix[..<space])
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lineCount(_ text: String, width: CGFloat, fontSize: CGFloat, stoppingAfter limit: Int) -> Int {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, stop in
            lines += 1
            stop.pointee = ObjCBool(lines > limit)
        }
        if layout.extraLineFragmentTextContainer != nil { lines += 1 }
        return lines
    }
}

struct OverviewFolderRow: View {
    let directory: String
    /// Read from the app's shared folder cache, the same check as the sidebar's folder token.
    let availability: ChannelFolderAvailability
    /// The channel visit the row belongs to, so an error stays with the channel it happened in.
    var visit = ""
    let channelURL: () -> URL?
    @ViewState private var errors = OverviewItemState<String?>(nil)

    private var error: String? {
        get { errors[visit] }
        nonmutating set { errors[visit] = newValue }
    }

    private var help: String {
        switch availability {
        case .openable: directory
        case .remote(let host): "On \(host): \(directory). Folders open only when the server runs on this Mac."
        case .missing: "This folder no longer exists: \(directory)"
        }
    }

    var body: some View {
        let revealable = availability == .openable
        VStack(alignment: .leading, spacing: 4) {
            OverviewPropertyRow(symbol: availability == .missing ? "questionmark.folder" : "folder") {
                HStack(spacing: 4) {
                    Text(ChannelFolderName.name(of: directory))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(help)
                        .accessibilityLabel("Folder")
                        .accessibilityValue(directory)
                        .accessibilityHint(revealable ? "" : help)
                    if revealable {
                        Button(action: showInFinder) {
                            Image(systemName: "arrow.forward.circle.fill")
                                .foregroundStyle(.tertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                        .accessibilityLabel("Show in Finder")
                    }
                    Spacer(minLength: 0)
                }
            }
            .contextMenu {
                if revealable { Button("Show in Finder", action: showInFinder) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(directory, forType: .string)
                }
                Button("Open in Toy Box") {
                    guard let url = channelURL() else {
                        error = "The channel URL is unavailable."
                        return
                    }
                    if !NSWorkspace.shared.open(url) { error = "Toy Box could not be opened." }
                }
            }
            if let error { ManagementError(message: error) }
        }
    }

    private func showInFinder() {
        // Reveals the folder in its parent, which never launches a package directory.
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: ChannelFolders.localPath(directory), isDirectory: true)])
    }
}

struct OverviewPreviewRow: View {
    @Environment(AppModel.self) private var app
    let preview: ChannelPreview
    let api: ChannelAPI
    let channelId: String
    /// The channel visit the row belongs to, so an error stays with the channel it happened in.
    let visit: String
    @ViewState private var errors = OverviewItemState<String?>(nil)

    private var error: String? {
        get { errors[visit] }
        nonmutating set { errors[visit] = newValue }
    }

    private var target: URL? {
        preview.kind == "url" ? preview.url.flatMap(api.resourceURL) : app.channelURL(channelID: channelId)
    }

    private var title: String {
        guard preview.kind == "url" else { return "Window preview" }
        guard let url = target, let host = url.host() else { return preview.url ?? "Preview" }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path() == "/" ? "" : url.path()
        return host + port + path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OverviewPropertyRow(symbol: "play.rectangle") {
                HStack(spacing: 0) {
                    Button(action: open) {
                        Text(title).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help(preview.kind == "url"
                          ? (target?.absoluteString ?? preview.url ?? "Preview")
                          : "Opens the channel in Toy Box, which shows this window preview.")
                    .accessibilityLabel("Preview, \(title)")
                    Spacer(minLength: 0)
                }
            }
            if let error { ManagementError(message: error) }
        }
    }

    private func open() {
        guard let target else { error = "The preview URL is unavailable."; return }
        error = NSWorkspace.shared.open(target) ? nil : "The preview could not be opened."
    }
}

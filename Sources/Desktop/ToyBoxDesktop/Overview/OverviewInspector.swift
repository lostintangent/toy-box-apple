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
/// About's purpose expansion. Rows keep that state per item and visit, so it never
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
    @SceneStorage("overviewTeamWorkingOnly") private var showsOnlyWorking = false
    @Binding var collapsed: Set<OverviewSectionID>

    var body: some View {
        let roster = store.roster
        OverviewSection(id: .team, summary: .team(roster.count),
                        filter: roster.isEmpty ? nil : ChannelOverviewFilter.workingAgents($showsOnlyWorking),
                        collapsed: $collapsed) {
            OverviewTeamList(store: store, showsOnlyWorking: showsOnlyWorking)
        }
    }
}

private struct OverviewTasksSection: View {
    @Environment(\.channelTextScale) private var textScale
    @SceneStorage("overviewTasksInProgressOnly") private var showsOnlyInProgress = false
    let store: ChannelStore
    @Binding var collapsed: Set<OverviewSectionID>
    let onArtifactOpen: (ChannelArtifact) -> Void

    var body: some View {
        let tasks = store.tasks
        let progress = tasks.progress
        let diff = tasks.diff
        OverviewSection(id: .tasks, summary: .tasks(progress),
                        accessibilityDetail: diff.map(ChannelOverviewTaskDiff.spoken),
                        filter: tasks.isEmpty ? nil : ChannelOverviewFilter.inProgressTasks($showsOnlyInProgress),
                        collapsed: $collapsed) {
            // The filter sits after the count it changes. The diff keeps the trailing facts slot.
            if let diff {
                ChannelOverviewTaskDiff(diff: diff)
                    .font(.system(size: 11 * textScale))
                    .accessibilityHidden(true)
            }
        } content: {
            OverviewTaskList(tasks: tasks, agents: store.roster, artifacts: store.artifacts,
                             channelId: store.id, showsOnlyInProgress: showsOnlyInProgress,
                             onArtifactOpen: onArtifactOpen)
        }
    }
}

private struct OverviewArtifactsSection: View {
    @Environment(ArtifactOpener.self) private var opener
    let store: ChannelStore
    @Binding var collapsed: Set<OverviewSectionID>
    @ViewState private var slots = OverviewSlots()

    var body: some View {
        let artifacts = store.artifacts.newestFirst
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
                                            agents: agents, store: store,
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
                Button("Add a purpose…") {
                    if let target = store.target { management.present(.editChannel(target)) }
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 13 * textScale))
                    .foregroundStyle(.secondary)
                    .disabled(!store.phase.isConnected)
                    .help(store.phase.isUnavailable ? "Available when the channel connects" : "Edit Channel")
            }
            let preview = details.preview
            if details.directory != nil || preview != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if let directory = details.directory, !directory.isEmpty {
                        OverviewFolderRow(
                            directory: directory,
                            availability: app.folderAvailability(path: directory, server: store.api.baseURL),
                            channelURL: { [app, id = store.id] in app.channelURL(channelID: id) })
                    }
                    if let preview {
                        OverviewPreviewRow(preview: preview, api: store.api)
                    }
                }
                .padding(.top, 10)
            }
        }
    }
}

/// Up to four lines of purpose with an inline Show More link that expands in place.
struct OverviewPurpose: View {
    static let lineLimit = 4
    static let showMore = "Show More"
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
            // The purpose is plain text, so its only link is the quiet secondary toggle.
            .tint(.secondary)
        Group {
            // Selectable text routes link clicks to its own text view, so a purpose that carries
            // the Show More or Show Less link stays plain and offers Copy from its context menu instead.
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
            link = AttributedString(Self.showMore)
        } else if collapsible {
            text = AttributedString(purpose + " ")
            link = AttributedString("Show Less")
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

    /// The longest prefix that still fits in four lines with "… Show More" after it, or nil when the purpose fits.
    static func truncated(_ text: String, width: CGFloat, fontSize: CGFloat) -> String? {
        guard requiresExpansion(text, width: width, fontSize: fontSize) else { return nil }
        let characters = Array(text)
        func fits(_ count: Int) -> Bool {
            let prefix = String(characters[..<count]).trimmingCharacters(in: .whitespacesAndNewlines)
            return lineCount(prefix + "… " + showMore, width: width, fontSize: fontSize, stoppingAfter: lineLimit)
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
    let channelURL: () -> URL?

    private var help: String {
        switch availability {
        case .openable: directory
        case .remote(let host): "On \(host): \(directory). Folders open only when the server runs on this Mac."
        case .missing: "This folder no longer exists: \(directory)"
        }
    }

    var body: some View {
        let revealable = availability == .openable
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
            let url = channelURL()
            Button("Open in Toy Box") { if let url { NSWorkspace.shared.open(url) } }
                .disabled(url == nil)
        }
    }

    private func showInFinder() {
        // Reveals the folder in its parent, which never launches a package directory.
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: ChannelFolders.localPath(directory), isDirectory: true)])
    }
}

struct OverviewPreviewRow: View {
    @Environment(\.openWindow) private var openWindow
    let preview: ChannelPreview
    let api: ChannelAPI

    private var target: URL? {
        preview.kind == "url" ? preview.url.flatMap(api.resourceURL) : nil
    }

    private var title: String {
        guard preview.kind == "url" else { return "Window preview" }
        guard let url = target, let host = url.host() else { return preview.url ?? "Preview" }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path() == "/" ? "" : url.path()
        return host + port + path
    }

    private var screenID: String? {
        preview.kind == "screen" ? preview.screenId : nil
    }

    var body: some View {
        OverviewPropertyRow(symbol: "play.rectangle") {
            HStack(spacing: 0) {
                Button(action: open) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
                .disabled(screenID == nil && target == nil)
                .help(preview.kind == "url"
                      ? (target?.absoluteString ?? preview.url ?? "Preview")
                      : "Opens this window preview")
                .accessibilityLabel("Preview, \(title)")
                Spacer(minLength: 0)
            }
        }
    }

    private func open() {
        if let screenID { return openWindow(id: "screens", value: screenID) }
        if let target { NSWorkspace.shared.open(target) }
    }
}

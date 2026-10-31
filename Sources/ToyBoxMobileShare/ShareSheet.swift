import ChannelKit
import SwiftUI
import ToyBoxMobileIntegrations
import ToyBoxUI

private typealias ViewState = SwiftUI.State

struct ShareSheet: View {
    @Bindable var session: MobileShareSession
    let close: () -> Void
    let finish: () -> Void
    let guardDismissal: (Bool) -> Void
    @ViewState private var choosing = false
    @ViewState private var sheetWidth: CGFloat?

    /// Close and the send control are 36-point circles ending at most 60 points in from the sheet's
    /// edges, so the channel button keeps that and 8 more clear on both sides. A long name truncates
    /// instead of running under them, and the button stays centered.
    private static let barItemReserve: CGFloat = 68

    var body: some View {
        NavigationStack {
            Group {
                if session.serverURL == nil {
                    ContentUnavailableView("Open Toy Box to connect first", systemImage: "network")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { closeButton } }
                } else if let message = session.contentError {
                    ContentUnavailableView("Can't Share This", systemImage: "square.and.arrow.up.trianglebadge.exclamationmark",
                                           description: Text(message))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { closeButton } }
                } else if let target = session.target {
                    ShareComposer(session: session)
                        .toolbar { composerToolbar(target) }
                        .navigationDestination(isPresented: $choosing) {
                            ShareChannelPicker(session: session) {
                                session.choose($0)
                                choosing = false
                            }
                        }
                } else {
                    ShareChannelPicker(session: session) { session.choose($0) }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { closeButton } }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sheetWidth = $0 }
        .onChange(of: [.sending, .sent].contains(session.phase)
                  || !session.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  initial: true) { guardDismissal($1) }
        .task(id: session.phase) {
            guard session.phase == .sent else { return }
            do {
                try await Task.sleep(for: .seconds(0.7))
                finish()
            } catch {}
        }
    }

    private var closeButton: some View {
        Button(role: .close, action: close)
            .disabled(session.phase == .sending || session.phase == .sent)
    }

    @ToolbarContentBuilder
    private func composerToolbar(_ target: MobileShareSession.Target) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { closeButton }
        ToolbarItem(placement: .principal) {
            Button { choosing = true } label: {
                WidthLimit(maximum: sheetWidth.map { max(0, $0 - 2 * Self.barItemReserve) }) {
                    HStack(spacing: 6) {
                        ChannelMark(size: 22)
                        Text(target.name).fontWeight(.semibold).lineLimit(1).foregroundStyle(Color.primary)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Color.secondary)
                    }
                }
            }
            .disabled(session.isLocked)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .accessibilityShowsLargeContentViewer()
            .accessibilityLabel("Channel, \(target.name)")
            .accessibilityHint("Chooses another channel.")
        }
        ToolbarItem(placement: .confirmationAction) {
            Group {
                switch session.phase {
                case .composing:
                    Button("Send", systemImage: "arrow.up") { Task { await session.send() } }
                        .buttonStyle(.glassProminent)
                        .disabled(!session.canSend)
                case .sending:
                    ProgressView().accessibilityLabel("Sending")
                case .sent:
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.tint, in: Circle())
                        .accessibilityLabel("Sent")
                case .unconfirmed, .offline:
                    Button("Send Again", systemImage: "arrow.clockwise") { Task { await session.send() } }
                        .buttonStyle(.glassProminent)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.large)
            .accessibilityShowsLargeContentViewer()
        }
    }
}

/// Proposes at most `maximum` points of width. The bar sizes its title to fit, which proposes no
/// width at all, so `frame(maxWidth:)` would clip a long name instead of truncating it.
private struct WidthLimit: Layout {
    var maximum: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(limited(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(bounds.size))
    }

    private func limited(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard let maximum else { return proposal }
        return ProposedViewSize(width: min(proposal.width ?? .infinity, maximum), height: proposal.height)
    }
}

private struct ShareComposer: View {
    @Bindable var session: MobileShareSession
    @FocusState private var noteFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                notice
                Group {
                    content
                    TextField("Add a note", text: $session.note, axis: .vertical)
                        .focused($noteFocused)
                    AudiencePill(text: session.note, agents: session.agents, acknowledgesRequest: false)
                }
                .disabled(session.isLocked)
                .opacity(session.isLocked ? 0.5 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { noteFocused = true }
    }

    @ViewBuilder private var notice: some View {
        switch session.phase {
        case .unconfirmed:
            ShareNotice(title: "Toy Box didn't confirm this.", detail: "Sending again can't post it twice.")
        case .offline:
            ShareNotice(title: "You're offline.", detail: "Nothing was sent.")
        default:
            if let notice = session.notice { ShareNotice(title: notice, detail: nil) }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.content {
        case .images(let images):
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(images) { image in
                        Image(decorative: image.thumbnail, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(images.count == 1 ? "1 image" : "\(images.count) images")
        case .link(let link):
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title3)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 44, height: 44)
                    .background(.primary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title ?? link.host).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(link.host).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        case nil:
            ProgressView().frame(height: 96)
        }
    }
}

private struct ShareNotice: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// Up to three recent channels, then the rest A to Z, like the Mac's Quick Send.
private struct ShareChannelPicker: View {
    let session: MobileShareSession
    let choose: (Channel) -> Void
    @ViewState private var query = ""

    var body: some View {
        let channels = session.catalog?.channels ?? []
        let choices = channelChoices(channels, query: query, recentIDs: session.recentChannelIDs)
        List {
            if let notice = session.notice {
                ShareNotice(title: notice, detail: nil).listRowBackground(Color.clear)
            }
            if !choices.recent.isEmpty {
                Section("Recent") { ForEach(choices.recent) { row($0) } }
            }
            if !choices.others.isEmpty {
                Section("All Channels") { ForEach(choices.others) { row($0) } }
            }
        }
        .overlay {
            if let catalog = session.catalog, !catalog.isLoaded {
                if let message = catalog.phase.message {
                    ContentUnavailableView {
                        Label("Can't Load Channels", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { Task { await session.refreshChannels() } }
                    }
                } else {
                    ProgressView()
                }
            } else if choices.recent.isEmpty, choices.others.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No Channels", systemImage: "bubble.left.and.bubble.right")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Channels")
        .navigationTitle("Choose a Channel")
        .refreshable { await session.refreshChannels() }
    }

    private func row(_ channel: Channel) -> some View {
        Button { choose(channel) } label: {
            HStack(spacing: 12) {
                ChannelMark(size: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).foregroundStyle(Color.primary)
                    if let purpose = channel.purpose, !purpose.isEmpty {
                        Text(purpose).font(.footnote).foregroundStyle(Color.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}


import ChannelClient
import ChannelKit
import Observation
import ToyBoxUI

enum ManagementField: Hashable {
    case name, purpose, role
}

@MainActor @Observable
final class ManagementSession {
    let flow: ManagementFlow
    let catalog: ChannelCatalogStore
    var channel: ChannelDetails?
    var member: ChannelAgent?
    var name = ""
    var purpose = ""
    var role = ""
    var model: ModelConfiguration?
    private(set) var openingModel: ModelConfiguration?
    var pending = false {
        didSet {
            if pending != oldValue { pendingSince = pending ? .now : nil }
        }
    }
    private(set) var pendingSince: ContinuousClock.Instant?
    var focus: ManagementField? = .name
    let recovery = ChannelManagementWriteRecovery()
    private(set) var hasLoaded = false
    var api: ChannelAPI { catalog.api }

    init(flow: ManagementFlow, catalog: ChannelCatalogStore) {
        self.flow = flow
        self.catalog = catalog
        if case .addMember(_, let name) = flow { self.name = name }
        if flow == .newChannel { hasLoaded = true }
    }

    func load(channel: ChannelDetails, member: ChannelAgent?) {
        guard !hasLoaded else { return }
        self.channel = channel
        self.member = member
        switch flow {
        case .editChannel:
            name = channel.name
            purpose = channel.purpose ?? ""
            model = channel.model
        case .editMember:
            name = member?.name ?? ""
            role = member?.role ?? ""
            model = member?.model
        default: break
        }
        openingModel = model
        hasLoaded = true
    }
}

@MainActor @Observable
final class ManagementSessions {
    @ObservationIgnored private(set) var current: ManagementSession?
    /// A deletion's session sits beside the editor's, so removing an agent from Edit Agent never replaces it.
    @ObservationIgnored private var deletion: ManagementSession?

    func session(for flow: ManagementFlow, catalog: ChannelCatalogStore) -> ManagementSession {
        if let existing = flow.isDeletion ? deletion : current,
           existing.flow == flow, existing.catalog === catalog { return existing }
        let session = ManagementSession(flow: flow, catalog: catalog)
        if flow.isDeletion { deletion = session } else { current = session }
        return session
    }

    func isCurrent(_ session: ManagementSession, app: AppModel, presenter: ManagementPresenter) -> Bool {
        current === session && app.catalog === session.catalog && presenter.flow == session.flow
    }

    func cancel(_ session: ManagementSession, presenter: ManagementPresenter) {
        guard current === session else { return }
        reset()
        presenter.flow = nil
    }

    func reset() {
        current = nil
        deletion = nil
    }
}

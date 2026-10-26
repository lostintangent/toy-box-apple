import ChannelClient
import ChannelKit
import Observation
import ToyBoxUI

enum ManagementField: Hashable {
    case name, purpose, role, directory
}

@MainActor @Observable
final class ManagementSession {
    let flow: ManagementFlow
    let catalog: ChannelCatalogStore
    var channel: ChannelDetails?
    var member: ChannelMember?
    var name = ""
    var purpose = ""
    var role = ""
    var directory = ""
    var model: ModelConfiguration?
    private(set) var openingModel: ModelConfiguration?
    var pending = false {
        didSet {
            if pending != oldValue { pendingSince = pending ? .now : nil }
        }
    }
    private(set) var pendingSince: ContinuousClock.Instant?
    var hasRequestedConfirmation = false
    var isConfirmationPresented = false
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

    func load(channel: ChannelDetails, member: ChannelMember?) {
        guard !hasLoaded else { return }
        self.channel = channel
        self.member = member
        switch flow {
        case .editChannel:
            name = channel.name
            purpose = channel.purpose ?? ""
            directory = channel.directory ?? ""
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
    @ObservationIgnored private var previousEditor: ManagementSession?

    func session(for flow: ManagementFlow, catalog: ChannelCatalogStore) -> ManagementSession {
        if let current, current.flow == flow, current.catalog === catalog { return current }
        if let previousEditor, previousEditor.flow == flow, previousEditor.catalog === catalog {
            current = previousEditor
            self.previousEditor = nil
            return previousEditor
        }
        if case .removeMember(let channel, let member) = flow,
           current?.flow == .editMember(channelId: channel, agentId: member) {
            previousEditor = current
        } else {
            previousEditor = nil
        }
        let session = ManagementSession(flow: flow, catalog: catalog)
        current = session
        return session
    }

    func isCurrent(_ session: ManagementSession, app: AppModel, presenter: ManagementPresenter) -> Bool {
        current === session && app.catalog === session.catalog && presenter.flow == session.flow
    }

    func cancel(_ session: ManagementSession, presenter: ManagementPresenter) {
        guard current === session else { return }
        if let previousEditor {
            current = previousEditor
            self.previousEditor = nil
            presenter.flow = previousEditor.flow
        } else {
            reset()
            presenter.flow = nil
        }
    }

    func reset() {
        current = nil
        previousEditor = nil
    }
}

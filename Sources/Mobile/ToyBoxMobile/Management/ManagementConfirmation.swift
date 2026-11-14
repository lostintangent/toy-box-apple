import ToyBoxClient
import SwiftUI
import ToyBoxUI

// The app is optional, so screens rendered without one simply have nothing to delete.
private struct AppManagementConfirmation: ViewModifier {
    @Binding var flow: ManagementFlow?
    let presenter: ManagementPresenter
    @Environment(AppModel.self) private var app: AppModel?

    func body(content: Content) -> some View {
        content.managementConfirmation($flow, presenter: presenter, catalogs: app?.catalogs ?? [],
                                       isActive: app?.isActive == true)
    }
}

extension View {
    /// Hosts the alert for a deletion `flow`. Every other flow is left to the host's sheet.
    func managementConfirmation(_ flow: Binding<ManagementFlow?>, presenter: ManagementPresenter) -> some View {
        modifier(AppManagementConfirmation(flow: flow, presenter: presenter))
    }

    /// Hosts the presenter's deletions while `hosting`, so only the frontmost screen asks.
    func managementConfirmation(presenter: ManagementPresenter, hosting: Bool) -> some View {
        managementConfirmation(Binding(get: { hosting ? presenter.flow : nil }, set: { presenter.flow = $0 }), presenter: presenter)
    }
}

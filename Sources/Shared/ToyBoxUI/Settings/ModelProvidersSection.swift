import ToyBoxClient
import ToyBoxKit
import SwiftUI

/// A server's model providers, read-only and in the server's order: each one's version, then its plan
/// and how much of each limit it has used, or why it isn't ready. The page showing it calls
/// `ServerProviders.appear()`, and a server that lists no providers shows no section. See Model
/// Providers in docs/spec.md.
public struct ModelProvidersSection: View {
    let providers: ServerProviders

    public init(_ providers: ServerProviders) {
        self.providers = providers
    }

    public var body: some View {
        if !providers.entries.isEmpty {
            Section("Model Providers") {
                ForEach(providers.entries) { entry in
                    ModelProviderRow(entry: entry)
                }
            }
        }
    }
}

private struct ModelProviderRow: View {
    let entry: ServerProviders.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.provider.name)
                if let version = entry.provider.version {
                    Text(version).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let end { Text(end).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            if entry.provider.enabled, entry.provider.status == .failed, let error = entry.provider.error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            switch entry.usage {
            case .loading?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            case .loaded(let subscription)?:
                if !subscription.limits.isEmpty { ModelProviderLimits(limits: subscription.limits) }
            case .none?, nil:
                EmptyView()
            }
        }
    }

    /// The end of the row: the plan once it's read, or why the provider isn't ready. A provider that
    /// isn't installed can't be turned on, so it says so even while it's off.
    private var end: String? {
        let provider = entry.provider
        if provider.status == .unavailable { return "Not Installed" }
        if !provider.enabled { return "Off" }
        switch provider.status {
        case .ready:
            guard case .loaded(let subscription)? = entry.usage, !subscription.planName.isEmpty else { return nil }
            return subscription.planName
        case .signedOut: return "Signed Out"
        case .failed: return "Failed"
        case .unavailable: return "Not Installed"
        }
    }
}

/// One line for each of a plan's limits, like the web: its name, a bar, its percent and when it resets.
private struct ModelProviderLimits: View {
    let limits: [ModelProviderLimit]
    @ScaledMetric(relativeTo: .subheadline) private var barWidth: CGFloat = 80

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            ForEach(limits, id: \.name) { limit in
                GridRow {
                    Text(limit.name).foregroundStyle(.secondary)
                    ProgressView(value: min(max(limit.usedPercent, 0), 100), total: 100)
                        .frame(width: barWidth)
                        // The percent beside it says the same.
                        .accessibilityHidden(true)
                    Text(limit.usedPercent / 100, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    if let resetsAt = limit.resetsAt {
                        Text(resetsAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

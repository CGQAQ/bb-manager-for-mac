import BBManagerKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let summary = model.clusterHealthSummary
        let scheduler = model.schedulerSummary
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.cluster.name).font(.headline)
                    HStack(spacing: 6) {
                        StatusDot(color: summary.color)
                        Text(summary.label).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isPolling {
                    ProgressView().controlSize(.small)
                }
            }

            if model.cluster.main != nil {
                Divider()
                VStack(spacing: 6) {
                    ForEach(model.allRoles, id: \.self) { role in
                        HStack {
                            Image(systemName: role.isMain ? "server.rack" : "cpu")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(model.title(for: role))
                            Spacer()
                            StatusDot(color: model.health(role).color)
                        }
                        .font(.callout)
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Actions").foregroundStyle(.secondary)
                        Text(Format.rate(model.clusterHistory.last?.actionsPerSecond)).monospacedDigit()
                    }
                    GridRow {
                        Text("Executing").foregroundStyle(.secondary)
                        Text(scheduler.map { "\($0.executing) of \($0.executorSlots)" } ?? "—").monospacedDigit()
                    }
                    GridRow {
                        Text("Queued").foregroundStyle(.secondary)
                        Text(scheduler.map { "\($0.queued)" } ?? "—").monospacedDigit()
                    }
                    GridRow {
                        Text("Cache hits").foregroundStyle(.secondary)
                        Text(Format.percent(model.frontendSummary?.actionCacheHitRate)).monospacedDigit()
                    }
                }
                .font(.callout)
            }

            Divider()
            HStack {
                Button("Open BB Manager") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if let url = model.portalURL {
                    Button("Portal") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button {
                    Task { await model.pollAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit BB Manager")
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

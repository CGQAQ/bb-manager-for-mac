import BBManagerKit
import SwiftUI

struct WorkerRow: Identifiable {
    var id: UUID
    var name: String
    var host: String
    var health: NodeHealth
    var kind: String
    var concurrency: Int
    var actions: String
    var cpu: String
    var deployed: String
    var pending: Bool
}

struct WorkersView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<UUID> = []

    var body: some View {
        Group {
            if model.cluster.workers.isEmpty {
                ContentUnavailableView {
                    Label("No Workers", systemImage: "cpu")
                } description: {
                    Text(model.cluster.main == nil
                         ? "Set up the main node first. Workers connect to its scheduler and storage."
                         : "Workers run build actions. Add one per machine.")
                } actions: {
                    if model.cluster.main == nil {
                        EmptyStateButton(title: "Set Up Main Node…") { model.sheet = .setUpMainNode }
                            .disabled(model.machines.isEmpty)
                    } else {
                        EmptyStateButton(title: "Add Worker…") { model.sheet = .addWorker(preselectedMachine: nil) }
                    }
                }
            } else {
                table
            }
        }
        .navigationTitle("Workers")
        .navigationSubtitle("\(model.cluster.workers.count) workers · \(model.generator.totalExecutorSlots) executor slots")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.sheet = .addWorker(preselectedMachine: nil)
                } label: {
                    Label("Add Worker", systemImage: "plus")
                }
                .disabled(model.cluster.main == nil)
                .help("Add a worker (⇧⌘N)")
            }
        }
    }

    private var rows: [WorkerRow] {
        model.cluster.workers.map { worker in
            let role = NodeRole.worker(worker.id)
            let machine = model.machine(worker.machineID)
            let sample = machine.flatMap { model.hostSamples[$0.id] }
            return WorkerRow(
                id: worker.id,
                name: machine?.displayName ?? "Unknown",
                host: machine?.host ?? "",
                health: model.health(role),
                kind: worker.settings.kind == .fuse ? "FUSE" : "Hardlinking",
                concurrency: worker.settings.concurrency,
                actions: Format.number(model.workerSummary(worker.id)?.actionsExecuted),
                cpu: Format.percent(sample?.cpuUsage),
                deployed: worker.deployedAt?.relativeDescription ?? "Never",
                pending: model.hasPendingChanges(role)
            )
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Machine") { row in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.name).fontWeight(.medium)
                        if row.pending {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                                .help("Configuration changes not deployed")
                        }
                    }
                    Text(row.host).font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Status") { row in
                HealthBadge(health: row.health)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Build Directory", value: \.kind)
                .width(min: 80, ideal: 100)
            TableColumn("Concurrency") { row in
                Text("\(row.concurrency)").monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Actions Run") { row in
                Text(row.actions).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Host CPU") { row in
                Text(row.cpu).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Deployed", value: \.deployed)
                .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                let role = NodeRole.worker(id)
                Button("Show Details") { model.selection = .worker(id) }
                Divider()
                Button("Restart") { model.compose(.restart, role: role) }
                Button("Stop") { model.compose(.stop, role: role) }
                Button("Start") { model.compose(.start, role: role) }
                Button("Apply Changes") { model.deploy(role) }
                    .disabled(!model.hasPendingChanges(role))
                Divider()
                Button("Remove Worker…", role: .destructive) { model.sheet = .removeNode(role) }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.selection = .worker(id) }
        }
    }
}

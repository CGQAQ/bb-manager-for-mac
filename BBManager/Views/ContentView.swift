import BBManagerKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            DetailView(selection: model.selection)
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .addMachine:
                MachineEditorSheet(machine: nil)
            case .editMachine(let id):
                MachineEditorSheet(machine: model.machine(id))
            case .setUpMainNode:
                SetUpMainNodeSheet()
            case .addWorker(let machineID):
                AddWorkerSheet(preselectedMachine: machineID)
            case .removeNode(let role):
                RemoveNodeSheet(role: role)
            }
        }
        .sheet(item: $model.operation) { session in
            OperationConsoleView(session: session)
        }
        .alert(item: $model.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }
        .task {
            model.startPolling()
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    var selection: SidebarItem?

    var body: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView()
        case .mainNode:
            if model.cluster.main != nil {
                NodeDetailView(role: .main)
                    .id(NodeRole.main)
            } else {
                MainNodeEmptyView()
            }
        case .workers:
            WorkersView()
        case .statistics:
            StatisticsView()
        case .configuration:
            ConfigurationView()
        case .worker(let id):
            if model.cluster.worker(id: id) != nil {
                NodeDetailView(role: .worker(id))
                    .id(NodeRole.worker(id))
            } else {
                ContentUnavailableView("Worker Removed", systemImage: "cpu", description: Text("This worker is no longer part of the cluster."))
            }
        case .machine(let id):
            if model.machine(id) != nil {
                MachineDetailView(machineID: id)
                    .id(id)
            } else {
                ContentUnavailableView("Machine Removed", systemImage: "server.rack")
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Cluster") {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.overview)
                HStack {
                    Label("Main Node", systemImage: "server.rack")
                    Spacer()
                    if model.cluster.main != nil {
                        StatusDot(color: model.health(.main).color)
                    }
                }
                .tag(SidebarItem.mainNode)
                Label("Workers", systemImage: "cpu")
                    .badge(model.cluster.workers.count)
                    .tag(SidebarItem.workers)
                Label("Statistics", systemImage: "chart.xyaxis.line")
                    .tag(SidebarItem.statistics)
                HStack {
                    Label("Configuration", systemImage: "slider.horizontal.3")
                    Spacer()
                    if model.allRoles.contains(where: model.hasPendingChanges) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.orange)
                            .help("Some nodes have configuration changes that are not deployed yet.")
                    }
                }
                .tag(SidebarItem.configuration)
            }

            if !model.cluster.workers.isEmpty {
                Section("Workers") {
                    ForEach(model.cluster.workers) { worker in
                        let role = NodeRole.worker(worker.id)
                        HStack {
                            Label(model.machine(worker.machineID)?.displayName ?? "Unknown", systemImage: "cpu.fill")
                            Spacer()
                            StatusDot(color: model.health(role).color)
                        }
                        .tag(SidebarItem.worker(worker.id))
                        .contextMenu {
                            Button("Restart") { model.compose(.restart, role: role) }
                            Button("Apply Changes") { model.deploy(role) }
                                .disabled(!model.hasPendingChanges(role))
                            Divider()
                            Button("Remove Worker…", role: .destructive) { model.sheet = .removeNode(role) }
                        }
                    }
                }
            }

            Section("Machines") {
                ForEach(model.machines) { machine in
                    MachineSidebarRow(machine: machine)
                        .tag(SidebarItem.machine(machine.id))
                        .contextMenu {
                            Button("Check Connection") { Task { await model.refreshFacts(machine.id) } }
                            Button("Edit…") { model.sheet = .editMachine(machine.id) }
                            Button("Open in Terminal") { model.openTerminal(machine) }
                            Divider()
                            Button("Remove", role: .destructive) { model.removeMachine(machine.id) }
                                .disabled(!model.canRemoveMachine(machine.id))
                        }
                }
                if model.machines.isEmpty {
                    Text("No machines yet")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    model.sheet = .addMachine
                } label: {
                    Label("Add Machine", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a machine reachable over SSH (⌘N)")
                Spacer()
                if model.isPolling {
                    ProgressView().controlSize(.small)
                } else if let lastPoll = model.lastPoll {
                    Text(lastPoll, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Last refreshed")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct MachineSidebarRow: View {
    @Environment(AppModel.self) private var model
    var machine: Machine

    var body: some View {
        let roles = model.roles(on: machine.id)
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(machine.displayName)
                    if !roles.isEmpty {
                        Text(roles.map { $0.isMain ? "Main" : "Worker" }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: roles.contains(.main) ? "server.rack" : "desktopcomputer")
            }
            Spacer()
            StatusDot(color: (model.connectivity[machine.id] ?? .unknown).color)
        }
    }
}

import BBManagerKit
import SwiftUI

struct MainNodeEmptyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No Main Node", systemImage: "server.rack")
        } description: {
            Text("The main node runs the Buildbarn frontend, storage, scheduler and portal. Pick one of your machines to host it.")
        } actions: {
            if model.machines.isEmpty {
                EmptyStateButton(title: "Add Machine…") { model.sheet = .addMachine }
            } else {
                EmptyStateButton(title: "Set Up Main Node…") { model.sheet = .setUpMainNode }
            }
        }
        .navigationTitle("Main Node")
    }
}

/// Machine readiness summary used by the setup sheets.
struct MachineReadiness: View {
    var machine: Machine?
    var needsFuse = false

    var body: some View {
        if let machine {
            if let facts = machine.facts {
                VStack(alignment: .leading, spacing: 4) {
                    check(facts.dockerReady, facts.dockerReady
                          ? "Docker \(facts.dockerVersion ?? "") with Compose \(facts.composeVersion ?? "")"
                          : "Docker or Docker Compose is missing — install it from the machine's page first.")
                    check(facts.hasHTTPClient == true, facts.hasHTTPClient == true ? "curl or wget available for metrics" : "Neither curl nor wget is installed; statistics will be empty.")
                    if needsFuse {
                        check(facts.hasFuse == true, facts.hasFuse == true ? "/dev/fuse available" : "No /dev/fuse — choose the hardlinking build directory.")
                    }
                    Text("\(facts.cpuCount ?? 0) CPUs · \(Format.bytes(facts.memoryBytes)) memory · \(Format.bytes(facts.diskAvailableBytes)) free disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("This machine has not been inspected yet. Use Check Connection on its page.", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func check(_ ok: Bool, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }
}

struct SetUpMainNodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var machineID: UUID?
    @State private var settings: MainNodeSettings?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Machine", selection: $machineID) {
                        ForEach(model.machines) { machine in
                            Text(machine.displayName).tag(Optional(machine.id))
                        }
                    }
                    MachineReadiness(machine: model.machine(machineID))
                } header: {
                    Text("Set Up Main Node")
                } footer: {
                    Text("BB Manager writes a docker-compose project to \(model.machine(machineID).map { ConfigGenerator.directory(for: .main, on: $0) } ?? "the install directory") and starts it.")
                }
                if let binding = Binding($settings) {
                    MainNodeSections(main: binding, machine: model.machine(machineID))
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Deploy Main Node") {
                    if let settings {
                        model.setUpMainNode(settings)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(settings == nil || settings?.advertisedAddress.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            }
            .padding(16)
        }
        .frame(width: 620, height: 720)
        .onAppear {
            if case .machine(let id) = model.selection { machineID = id } else { machineID = model.machines.first?.id }
        }
        .onChange(of: machineID) { _, id in
            guard let machine = model.machine(id) else { return }
            var draft = settings ?? MainNodeSettings(machineID: machine.id, advertisedAddress: "")
            draft.machineID = machine.id
            draft.advertisedAddress = Self.defaultAddress(for: machine)
            if let disk = machine.facts?.diskAvailableBytes, settings == nil {
                // Default to at most half of the free disk for the CAS.
                let halfGiB = Double(disk) / 2 / 1024 / 1024 / 1024
                draft.storage.casSizeGiB = max(4, min(draft.storage.casSizeGiB, (halfGiB / 8).rounded(.down) * 8))
            }
            settings = draft
        }
    }

    static func defaultAddress(for machine: Machine) -> String {
        let host = machine.host
        let looksRoutable = host.contains(".") || host.contains(":")
        if looksRoutable { return host }
        return machine.facts?.primaryAddress ?? host
    }
}

struct AddWorkerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var preselectedMachine: UUID?
    @State private var machineID: UUID?
    @State private var settings = WorkerSettings()

    private var candidates: [Machine] {
        model.machines.filter { machine in !model.cluster.workers.contains { $0.machineID == machine.id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if candidates.isEmpty {
                        Text("Every machine already runs a worker. Add another machine first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Machine", selection: $machineID) {
                            ForEach(candidates) { machine in
                                Text(machine.displayName).tag(Optional(machine.id))
                            }
                        }
                        MachineReadiness(machine: model.machine(machineID), needsFuse: settings.kind == .fuse)
                    }
                } header: {
                    Text("Add Worker")
                } footer: {
                    Text("The worker registers with the scheduler at \(model.cluster.main.map { "\($0.advertisedAddress):\($0.schedulerWorkerPort)" } ?? "the main node").")
                }
                if machineID != nil {
                    WorkerSettingsSections(settings: $settings, machine: model.machine(machineID))
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Deploy Worker") {
                    if let machineID {
                        model.addWorker(WorkerNode(machineID: machineID, settings: settings))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(machineID == nil || model.cluster.main == nil)
            }
            .padding(16)
        }
        .frame(width: 620, height: 720)
        .onAppear {
            settings = model.cluster.workerDefaults
            machineID = candidates.first { $0.id == preselectedMachine }?.id ?? candidates.first?.id
        }
        .onChange(of: machineID, initial: true) { _, id in
            guard let machine = model.machine(id) else { return }
            if let cpus = machine.facts?.cpuCount, cpus > 0 {
                settings.concurrency = cpus
            }
            if machine.facts?.hasFuse == false {
                settings.kind = .hardlinking
            } else {
                settings.kind = model.cluster.workerDefaults.kind
            }
        }
    }
}

struct RemoveNodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let role: NodeRole
    @State private var deleteData = false

    var body: some View {
        let machine = model.machine(for: role)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remove \(model.title(for: role))?")
                        .font(.title3.weight(.semibold))
                    Text("BB Manager stops and removes the containers on \(machine?.displayName ?? "the machine").")
                        .foregroundStyle(.secondary)
                    if role.isMain && !model.cluster.workers.isEmpty {
                        Label("Workers lose their scheduler and storage until a new main node is set up.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Toggle(isOn: $deleteData) {
                Text("Also delete \(model.plan(role)?.directory ?? "its directory")")
                Text("Removes configuration and cached data. This cannot be undone.")
            }
            .toggleStyle(.checkbox)
            HStack {
                Button("Forget Only") {
                    model.forgetNode(role)
                    dismiss()
                }
                .help("Remove from BB Manager without touching the machine")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    model.removeNode(role, deleteData: deleteData)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

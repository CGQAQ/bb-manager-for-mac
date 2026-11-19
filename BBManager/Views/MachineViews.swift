import AppKit
import BBManagerKit
import Charts
import SwiftUI

// MARK: - Detail

struct MachineDetailView: View {
    @Environment(AppModel.self) private var model
    var machineID: UUID
    @State private var confirmRemove = false
    @State private var confirmDocker = false

    var body: some View {
        if let machine = model.machine(machineID) {
            content(machine)
        }
    }

    private func content(_ machine: Machine) -> some View {
        let connectivity = model.connectivity[machine.id] ?? .unknown
        let sample = model.hostSamples[machine.id]
        let facts = machine.facts
        let roles = model.roles(on: machine.id)
        return Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: roles.contains(.main) ? "server.rack" : "desktopcomputer")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .frame(width: 48, height: 48)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(machine.displayName).font(.title2.weight(.semibold))
                        Text(machine.sshDestination + (machine.port == 22 ? "" : ":\(machine.port)"))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    ConnectivityBadge(connectivity: connectivity)
                }
                .padding(.vertical, 4)
                banners(machine, connectivity: connectivity)
            }

            if let sample {
                Section("Utilization") {
                    UsageRow(title: "CPU", value: sample.cpuUsage, detail: sample.load1.map { String(format: "load %.2f  %.2f  %.2f", $0, sample.load5 ?? 0, sample.load15 ?? 0) })
                    UsageRow(title: "Memory", value: sample.memoryUsage, detail: sample.memoryTotal.map { "\(Format.bytes(($0 - (sample.memoryAvailable ?? 0)))) of \(Format.bytes($0))" })
                    UsageRow(title: "Disk", value: sample.diskUsage, detail: sample.diskAvailable.map { "\(Format.bytes($0)) free at \(machine.installDirectory)" })
                    if let history = model.hostHistory[machine.id], history.count > 1 {
                        HostHistoryChart(points: history)
                            .frame(height: 120)
                            .padding(.vertical, 4)
                    }
                }
            }

            let external = model.unmanagedProjects(on: machine.id)
            if !external.isEmpty {
                Section {
                    ForEach(external) { project in
                        ExternalProjectRow(project: project, machineID: machine.id)
                    }
                } header: {
                    Text("Other Buildbarn Deployments")
                } footer: {
                    Text("Started outside BB Manager. Take Over reads its settings from the running containers, stops it, and redeploys it as a BB Manager main node and worker with the same ports, instance name and platform. Its folder is kept, and if anything fails it is started again.")
                }
            }

            Section("Roles") {
                if roles.isEmpty {
                    Text("This machine is not part of the cluster yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(roles, id: \.self) { role in
                    LabeledContent {
                        HStack {
                            HealthBadge(health: model.health(role))
                            Button("Show") {
                                model.selection = role.isMain ? .mainNode : .worker(role.workerID!)
                            }
                        }
                    } label: {
                        Label(role.isMain ? "Main Node" : "Worker", systemImage: role.isMain ? "server.rack" : "cpu")
                    }
                }
                HStack {
                    if model.cluster.main == nil {
                        Button("Use as Main Node…") { model.sheet = .setUpMainNode }
                    }
                    if model.cluster.main != nil && !roles.contains(where: { !$0.isMain }) {
                        Button("Add as Worker…") { model.sheet = .addWorker(preselectedMachine: machine.id) }
                    }
                }
            }

            Section("Connection") {
                LabeledContent("Host", value: machine.host)
                LabeledContent("Port", value: String(machine.port))
                LabeledContent("User", value: machine.user.isEmpty ? "From ~/.ssh/config" : machine.user)
                LabeledContent("Authentication", value: machine.auth == .identityFile ? machine.identityFile : machine.auth.label)
                LabeledContent("Privileges", value: machine.privilege.label)
                LabeledContent("Install Directory", value: machine.installDirectory)
            }

            Section {
                if let facts {
                    LabeledContent("Operating System", value: facts.osName ?? "—")
                    LabeledContent("Kernel", value: [facts.kernel, facts.architecture].compactMap { $0 }.joined(separator: " · "))
                    LabeledContent("CPUs", value: facts.cpuCount.map(String.init) ?? "—")
                    LabeledContent("Memory", value: Format.bytes(facts.memoryBytes))
                    LabeledContent("Primary Address", value: facts.primaryAddress ?? "—")
                    LabeledContent("Docker", value: nonEmpty(facts.dockerVersion) ?? "Not available")
                    LabeledContent("Docker Compose", value: nonEmpty(facts.composeVersion) ?? "Not available")
                    LabeledContent("FUSE", value: facts.hasFuse == true ? "Available" : "Not available (use hardlinking workers)")
                    LabeledContent("curl / wget", value: facts.hasHTTPClient == true ? "Available" : "Missing — metrics need one of them")
                    LabeledContent("Disk Free", value: "\(Format.bytes(facts.diskAvailableBytes)) of \(Format.bytes(facts.diskTotalBytes))")
                } else {
                    Text("Not inspected yet.").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("System")
                    Spacer()
                    if let facts {
                        Text("checked \(facts.checkedAt.relativeDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            let usage = (model.containerUsage[machine.id] ?? []).filter { $0.name.hasPrefix("buildbarn-") }
            if !usage.isEmpty {
                Section("Buildbarn Containers") {
                    ForEach(usage) { container in
                        LabeledContent {
                            Text("\(String(format: "%.1f", container.cpuPercent))% CPU · \(container.memoryUsage)")
                                .monospacedDigit()
                        } label: {
                            Text(container.name).font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(machine.displayName)
        .navigationSubtitle(machine.host)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshFacts(machine.id) }
                } label: {
                    Label("Check Connection", systemImage: "arrow.clockwise")
                }
                .help("Reconnect and re-inspect the machine")
                Button {
                    model.openTerminal(machine)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .help("Open an SSH session in Terminal")
                Button {
                    model.sheet = .editMachine(machine.id)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Menu {
                    Button("Install Docker…") { confirmDocker = true }
                    Divider()
                    Button("Remove Machine…", role: .destructive) { confirmRemove = true }
                        .disabled(!model.canRemoveMachine(machine.id))
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Remove \(machine.displayName)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.removeMachine(machine.id) }
        } message: {
            Text("BB Manager forgets this machine and its stored password. Nothing on the machine is changed.")
        }
        .confirmationDialog("Install Docker on \(machine.displayName)?", isPresented: $confirmDocker) {
            Button("Install Docker") { model.installDocker(on: machine.id) }
        } message: {
            Text("This downloads and runs Docker's official convenience script (get.docker.com) on the machine with root privileges.")
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// At most one banner, most actionable first.
    @ViewBuilder
    private func banners(_ machine: Machine, connectivity: Connectivity) -> some View {
        let facts = machine.facts
        let user = machine.user.isEmpty ? "This user" : machine.user
        if case .offline(let message) = connectivity {
            Banner(symbol: "bolt.horizontal.circle.fill", tint: .red, text: message)
        } else if let facts, facts.shouldUseDockerGroup, machine.privilege != .none {
            let newDirectory = model.roles(on: machine.id).contains { model.deployedAt($0) != nil }
                ? nil : facts.dockerGroupInstallDirectory(current: machine.installDirectory)
            Banner(
                symbol: "person.badge.key.fill",
                tint: .orange,
                text: "sudo needs a password here, but \(user) can use Docker directly (docker group)."
                    + (newDirectory.map { " BB Manager will install into \($0) because \(machine.installDirectory) needs root." } ?? ""),
                actionTitle: "Use Docker Without sudo"
            ) {
                model.useDockerGroup(machine.id)
            }
        } else if case .limited(let message) = connectivity {
            Banner(symbol: "lock.trianglebadge.exclamationmark.fill", tint: .orange, text: message, actionTitle: "Edit…") {
                model.sheet = .editMachine(machine.id)
            }
        } else if let error = facts?.privilegeError {
            Banner(symbol: "lock.trianglebadge.exclamationmark.fill", tint: .orange, text: "Privileged commands failed: \(error)", actionTitle: "Edit…") {
                model.sheet = .editMachine(machine.id)
            }
        } else if let facts, facts.dockerVersion?.isEmpty ?? false {
            Banner(symbol: "shippingbox", tint: .orange, text: "Docker is not installed.", actionTitle: "Install Docker…") {
                confirmDocker = true
            }
        } else if let facts, facts.dockerVersion?.isEmpty == false, facts.composeVersion?.isEmpty ?? true {
            Banner(symbol: "shippingbox", tint: .orange, text: "Docker is installed but the Compose plugin is missing. Install the docker-compose-plugin package.")
        }
    }
}

struct ExternalProjectRow: View {
    @Environment(AppModel.self) private var model
    var project: ComposeProject
    var machineID: UUID

    var body: some View {
        let blocker = model.takeOverBlocker(on: machineID)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Text(project.name).fontWeight(.medium)
                Text("\(project.runningCount) of \(project.containers.count) running")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button {
                    model.takeOver(project, on: machineID)
                } label: {
                    Label("Take Over", systemImage: "arrow.down.to.line.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocker != nil)
                .help(blocker ?? "Make \(project.name) a BB Manager–managed main node and worker")
            }
            Text(project.workingDirectory)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            services
                .font(.callout)
            if !project.hostPorts.isEmpty {
                Text("Ports: " + project.hostPorts.sorted().map(String.init).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Service names with a status dot each; wraps like text.
    private var services: Text {
        project.containers.enumerated().reduce(Text("")) { text, item in
            let container = item.element
            let color: Color = container.isRunning ? .green : (container.service.contains("installer") ? .secondary : .red)
            let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 7)).foregroundStyle(color)
            return text + (item.offset == 0 ? Text("") : Text("    ")) + dot + Text(" " + container.service)
        }
    }
}

struct UsageRow: View {
    var title: String
    var value: Double?
    var detail: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: min(1, max(0, value ?? 0)))
                    .tint(tint)
                    .frame(width: 120)
                Text(Format.percent(value))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }

    private var tint: Color {
        guard let value else { return .secondary }
        return value > 0.9 ? .red : value > 0.75 ? .orange : .accentColor
    }
}

struct HostHistoryChart: View {
    var points: [HostPoint]

    var body: some View {
        Chart {
            ForEach(points) { point in
                if let cpu = point.cpu {
                    LineMark(x: .value("Time", point.date), y: .value("Percent", cpu * 100))
                        .foregroundStyle(by: .value("Series", "CPU"))
                        .interpolationMethod(.monotone)
                }
                if let memory = point.memory {
                    LineMark(x: .value("Time", point.date), y: .value("Percent", memory * 100))
                        .foregroundStyle(by: .value("Series", "Memory"))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
            }
        }
        .chartForegroundStyleScale(["CPU": Color.blue, "Memory": Color.purple])
    }
}

// MARK: - Editor

struct MachineEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var draft: Machine
    @State private var password = ""
    @State private var testState: TestState = .idle
    @State private var wroteTemporaryPassword = false

    enum TestState {
        case idle
        case testing
        case success(MachineFacts, note: String?, warning: String?)
        case failure(String)
    }

    init(machine: Machine?) {
        isNew = machine == nil
        _draft = State(initialValue: machine ?? Machine())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text(draft.host.isEmpty ? "build-01" : draft.host))
                    TextField("Host", text: $draft.host, prompt: Text("hostname, IP, or ~/.ssh/config alias"))
                    TextField("Port", value: $draft.port, format: .number.grouping(.never))
                    TextField("User", text: $draft.user, prompt: Text("default from ~/.ssh/config"))
                } header: {
                    Text(isNew ? "Add Machine" : "Edit Machine")
                } footer: {
                    Text("Linux hosts with Docker. BB Manager connects with the system OpenSSH client, so ProxyJump and other ~/.ssh/config settings apply.")
                }

                Section("Authentication") {
                    Picker("Method", selection: $draft.auth) {
                        ForEach(AuthMethod.allCases) { Text($0.label).tag($0) }
                    }
                    if draft.auth == .identityFile {
                        LabeledContent("Private Key") {
                            HStack {
                                TextField("Private Key", text: $draft.identityFile, prompt: Text("~/.ssh/id_ed25519"))
                                    .labelsHidden()
                                Button("Choose…", action: chooseKey)
                            }
                        }
                    }
                    if draft.needsStoredPassword {
                        SecureField(draft.auth == .password ? "Password" : "sudo Password", text: $password,
                                    prompt: Text(isNew ? "" : "unchanged"))
                        Text("Stored in your login Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Privileged Commands", selection: $draft.privilege) {
                        ForEach(PrivilegeMode.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Install Directory", text: $draft.installDirectory)
                } header: {
                    Text("Privileges")
                } footer: {
                    Text("Docker and the install directory usually need root. Use sudo unless you log in as root.")
                }

                Section("Connection Test") {
                    HStack {
                        Button("Test Connection", action: test)
                            .disabled(!draft.validationErrors.isEmpty || isTesting)
                        if isTesting {
                            ProgressView().controlSize(.small)
                            Text("Connecting…").foregroundStyle(.secondary)
                        }
                    }
                    testResult
                }

                if !draft.validationErrors.isEmpty && !draft.host.isEmpty {
                    Section {
                        ForEach(draft.validationErrors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Machine" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.validationErrors.isEmpty || (isNew && draft.needsStoredPassword && password.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 560, height: 680)
    }

    private var isTesting: Bool { if case .testing = testState { true } else { false } }

    @ViewBuilder private var testResult: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case .failure(let message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        case .success(let facts, let note, let warning):
            VStack(alignment: .leading, spacing: 6) {
                Label("Connected to \(facts.osName ?? "machine")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(facts.cpuCount ?? 0) CPUs · \(Format.bytes(facts.memoryBytes)) memory · \(facts.architecture ?? "")")
                    .foregroundStyle(.secondary)
                if let docker = facts.dockerVersion, !docker.isEmpty {
                    Text("Docker \(docker) · Compose \(facts.composeVersion ?? "missing")").foregroundStyle(.secondary)
                } else if facts.privilegeError == nil {
                    Text("Docker not found — you can install it from the machine's page after adding it.").foregroundStyle(.orange)
                }
                if let note {
                    Label(note, systemImage: "info.circle.fill").foregroundStyle(.blue)
                }
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.prompt = "Choose Key"
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    private func normalizedDraft() -> Machine {
        var machine = draft
        machine.host = machine.host.trimmingCharacters(in: .whitespaces)
        machine.user = machine.user.trimmingCharacters(in: .whitespaces)
        machine.name = machine.name.trimmingCharacters(in: .whitespaces)
        if machine.name.isEmpty { machine.name = machine.host }
        return machine
    }

    private func test() {
        let machine = normalizedDraft()
        if !password.isEmpty {
            do {
                try Keychain.setPassword(password, account: machine.keychainAccount)
                if isNew { wroteTemporaryPassword = true }
            } catch {
                testState = .failure(error.localizedDescription)
                return
            }
        }
        testState = .testing
        model.ssh.closeMaster(machine)
        Task {
            do {
                var facts = try await model.inspect(machine)
                var note: String?
                var warning: String?
                if facts.isRoot == true && draft.privilege != .none {
                    draft.privilege = .none
                    facts = try await model.inspect(normalizedDraft())
                } else if facts.shouldUseDockerGroup && draft.privilege != .none {
                    // sudo wants a password but Docker works for this user: use the docker group.
                    draft.facts = facts
                    let previousDirectory = draft.installDirectory
                    draft.adoptDockerGroup()
                    note = "sudo needs a password here, but this user is in the docker group, so BB Manager will run Docker without sudo"
                        + (draft.installDirectory != previousDirectory ? " and install into \(draft.installDirectory)." : ".")
                    facts = try await model.inspect(normalizedDraft())
                }
                if let error = facts.privilegeError {
                    warning = "Privileged commands failed: \(error)"
                } else if facts.isRoot == false && facts.passwordlessSudo == false && draft.privilege == .sudo {
                    warning = "Passwordless sudo is not available. Choose “sudo with password” or add the user to the docker group."
                }
                draft.facts = facts
                testState = .success(facts, note: note, warning: warning)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private func save() {
        let machine = normalizedDraft()
        model.saveMachine(machine, password: password.isEmpty ? nil : password)
        dismiss()
    }

    private func cancel() {
        if wroteTemporaryPassword {
            Keychain.deletePassword(account: draft.keychainAccount)
        }
        dismiss()
    }
}

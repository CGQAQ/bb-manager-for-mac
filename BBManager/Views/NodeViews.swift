import BBManagerKit
import SwiftUI

enum NodeTab: String, CaseIterable, Identifiable {
    case services = "Services"
    case logs = "Logs"
    case settings = "Settings"
    case files = "Files"

    var id: String { rawValue }
}

struct NodeDetailView: View {
    @Environment(AppModel.self) private var model
    let role: NodeRole
    @State private var tab: NodeTab = NodeTab(rawValue: UserDefaults.standard.string(forKey: "BBMInitialTab") ?? "") ?? .services
    @State private var logService: String?

    var body: some View {
        VStack(spacing: 0) {
            NodeHeader(role: role)
            Divider()
            Group {
                switch tab {
                case .services:
                    ServicesTab(role: role, tab: $tab, logService: $logService)
                case .logs:
                    LogsTab(role: role, service: $logService)
                case .settings:
                    if role.isMain {
                        MainSettingsForm()
                    } else if let id = role.workerID, let index = model.cluster.workers.firstIndex(where: { $0.id == id }) {
                        WorkerNodeSettingsForm(index: index)
                    }
                case .files:
                    FilesTab(role: role)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.requestedNodeTab, initial: true) { _, requested in
            guard let requested else { return }
            tab = requested
            model.requestedNodeTab = nil
        }
        .navigationTitle(model.title(for: role))
        .navigationSubtitle(model.machine(for: role)?.host ?? "")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(NodeTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                NodeActions(role: role)
            }
        }
    }
}

struct NodeActions: View {
    @Environment(AppModel.self) private var model
    let role: NodeRole

    var body: some View {
        let busy = model.busyNodes.contains(role)
        let deployed = model.deployedAt(role) != nil
        if busy {
            ProgressView().controlSize(.small)
        }
        Button {
            model.compose(.start, role: role)
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .help("Start all services")
        .disabled(busy || !deployed)
        Button {
            model.compose(.stop, role: role)
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .help("Stop all services")
        .disabled(busy || !deployed)
        Button {
            model.compose(.restart, role: role)
        } label: {
            Label("Restart", systemImage: "arrow.clockwise")
        }
        .help("Restart all services")
        .disabled(busy || !deployed)
        Menu {
            Button(deployed ? "Apply Changes" : "Deploy") { model.deploy(role) }
            Button("Update Images && Redeploy") { model.updateImages(role) }
                .disabled(!deployed)
            Button("Redeploy Without Pulling") { model.deploy(role, pullImages: false) }
                .disabled(!deployed)
            Divider()
            Button(role.isMain ? "Remove Main Node…" : "Remove Worker…", role: .destructive) {
                model.sheet = .removeNode(role)
            }
        } label: {
            Label("Deploy", systemImage: "shippingbox.and.arrow.backward")
        } primaryAction: {
            model.deploy(role)
        }
        .help(deployed ? "Apply configuration changes" : "Deploy to the machine")
    }
}

struct NodeHeader: View {
    @Environment(AppModel.self) private var model
    let role: NodeRole

    var body: some View {
        let machine = model.machine(for: role)
        let health = model.health(role)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: role.isMain ? "server.rack" : "cpu")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title(for: role)).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        if let machine {
                            Button(machine.displayName) { model.selection = .machine(machine.id) }
                                .buttonStyle(.link)
                        }
                        Text("·").foregroundStyle(.tertiary)
                        Text(model.plan(role)?.directory ?? "")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HealthBadge(health: health)
                    if let deployedAt = model.deployedAt(role) {
                        Text("Deployed \(deployedAt.relativeDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if model.deployedAt(role) == nil {
                Banner(symbol: "shippingbox", tint: .accentColor, text: "This node has not been deployed yet.", actionTitle: "Deploy") {
                    model.deploy(role)
                }
            } else if model.hasPendingChanges(role) {
                Banner(symbol: "arrow.triangle.2.circlepath", tint: .orange, text: "Configuration changed since the last deployment.", actionTitle: "Apply Changes") {
                    model.deploy(role)
                }
            }
            if let error = model.nodeRuntime[role]?.error, health == .unreachable {
                Banner(symbol: "bolt.horizontal.circle.fill", tint: .red, text: error)
            }
            let conflicts = model.portConflicts(role)
            if !conflicts.isEmpty, let machine {
                let ports = conflicts.map { String($0.port) }.joined(separator: ", ")
                let names = Set(conflicts.map(\.project)).sorted()
                let projects = model.unmanagedProjects(on: machine.id).filter { names.contains($0.name) }
                // One conflicting deployment on the main node's machine: offer to take it over.
                if role.isMain, projects.count == 1, let project = projects.first, model.takeOverBlocker(on: machine.id) == nil {
                    Banner(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        text: "Port\(conflicts.count == 1 ? "" : "s") \(ports) \(conflicts.count == 1 ? "is" : "are") used by \(project.name), which runs here outside BB Manager. Take it over to manage it from here with its current settings.",
                        actionTitle: "Take Over \(project.name)"
                    ) {
                        model.takeOver(project, on: machine.id)
                    }
                } else {
                    Banner(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        text: "Port\(conflicts.count == 1 ? "" : "s") \(ports) \(conflicts.count == 1 ? "is" : "are") already used by \(names.joined(separator: ", ")) on this machine. Stop it or change the ports in Settings before deploying.",
                        actionTitle: "Show Machine"
                    ) {
                        model.selection = .machine(machine.id)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Services

struct ServiceRow: Identifiable, Hashable {
    var id: String { service }
    var service: String
    var state: String
    var status: String
    var image: String
    var ports: String
    var running: Bool
    var oneShot: Bool
    var cpu: String
    var memory: String
}

struct ServicesTab: View {
    @Environment(AppModel.self) private var model
    let role: NodeRole
    @Binding var tab: NodeTab
    @Binding var logService: String?
    @State private var selection: Set<String> = []

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            NodeStatsStrip(role: role)
            Table(rows, selection: $selection) {
                TableColumn("Service") { row in
                    HStack(spacing: 8) {
                        StatusDot(color: color(row))
                        Text(row.service).fontWeight(.medium)
                    }
                }
                .width(min: 120, ideal: 160)
                TableColumn("Status") { row in
                    Text(row.status).foregroundStyle(row.running ? .primary : .secondary)
                }
                .width(min: 120, ideal: 170)
                TableColumn("CPU") { row in
                    Text(row.cpu).monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("Memory") { row in
                    Text(row.memory).monospacedDigit()
                }
                .width(min: 60, ideal: 80)
                TableColumn("Ports") { row in
                    Text(row.ports).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 200)
                TableColumn("Image") { row in
                    Text(Format.shortImage(row.image))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help(row.image)
                }
                .width(min: 120, ideal: 260)
            }
            .contextMenu(forSelectionType: String.self) { services in
                if let service = services.first {
                    Button("Show Logs") { showLogs(service) }
                    Divider()
                    Button("Start") { model.compose(.start, role: role, service: service) }
                    Button("Stop") { model.compose(.stop, role: role, service: service) }
                    Button("Restart") { model.compose(.restart, role: role, service: service) }
                }
            } primaryAction: { services in
                if let service = services.first { showLogs(service) }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Containers", systemImage: "shippingbox", description: Text(model.deployedAt(role) == nil ? "Deploy the node to create its containers." : "Waiting for status…"))
                }
            }
        }
    }

    private func showLogs(_ service: String) {
        logService = service
        tab = .logs
    }

    private func color(_ row: ServiceRow) -> Color {
        if row.running { return .green }
        if row.oneShot && row.state == "exited" { return .secondary }
        return row.state.isEmpty ? .secondary : .red
    }

    private var rows: [ServiceRow] {
        let runtime = model.nodeRuntime[role]
        let containers = runtime?.containers ?? []
        let usage = model.machine(for: role).flatMap { model.containerUsage[$0.id] } ?? []
        var rows: [ServiceRow] = containers.map { container in
            let stats = usage.first { $0.name == container.name }
            return ServiceRow(
                service: container.service,
                state: container.state.lowercased(),
                status: container.status.isEmpty ? container.state : container.status,
                image: container.image,
                ports: container.publishedPorts,
                running: container.isRunning,
                oneShot: container.isOneShot,
                cpu: stats.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "—",
                memory: stats?.memoryUsage ?? "—"
            )
        }
        if let plan = model.plan(role), runtime?.lastUpdated != nil, model.deployedAt(role) != nil {
            for service in plan.services where !rows.contains(where: { $0.service == service }) {
                rows.append(ServiceRow(service: service, state: "", status: "Not created", image: "", ports: "", running: false, oneShot: false, cpu: "—", memory: "—"))
            }
        }
        return rows
    }
}

/// Key numbers for a node, shown above its services table.
struct NodeStatsStrip: View {
    @Environment(AppModel.self) private var model
    let role: NodeRole

    var body: some View {
        let items = self.items
        if !items.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().frame(height: 30) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.caption).foregroundStyle(.secondary)
                        Text(item.1).font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
        }
    }

    private var items: [(String, String)] {
        switch role {
        case .main:
            guard let scheduler = model.schedulerSummary else { return [] }
            let latest = model.clusterHistory.last
            return [
                ("Executor slots", "\(scheduler.executorSlots)"),
                ("Executing", "\(scheduler.executing)"),
                ("Queued", "\(scheduler.queued)"),
                ("Actions", Format.rate(latest?.actionsPerSecond)),
                ("Cache hit rate", Format.percent(model.frontendSummary?.actionCacheHitRate)),
            ]
        case .worker(let id):
            guard let worker = model.cluster.worker(id: id) else { return [] }
            let summary = model.workerSummary(id)
            let process = model.metrics[MetricsKey(role: role, service: "worker")].map(ProcessSummary.init)
            return [
                ("Concurrency", worker.settings.slotsDescription),
                ("Actions run", Format.number(summary?.actionsExecuted)),
                ("Worker memory", Format.bytes(process?.residentMemoryBytes)),
                ("Uptime", process?.startTime.map { Format.duration(Date().timeIntervalSince($0)) } ?? "—"),
            ]
        }
    }
}

// MARK: - Logs

struct LogsTab: View {
    @Environment(AppModel.self) private var model
    let role: NodeRole
    @Binding var service: String?
    @State private var buffer = LogBuffer()
    @State private var follow = true
    @State private var tail = 300
    @State private var reloadToken = 0
    @State private var status: String?

    private struct StreamKey: Hashable {
        var service: String?
        var follow: Bool
        var tail: Int
        var token: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Service", selection: $service) {
                    Text("All Services").tag(String?.none)
                    Divider()
                    ForEach(model.plan(role)?.services ?? [], id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .frame(width: 220)
                Picker("Lines", selection: $tail) {
                    ForEach([100, 300, 1000, 5000], id: \.self) { Text("Last \($0)").tag($0) }
                }
                .frame(width: 150)
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                Spacer()
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    reloadToken += 1
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Reload logs")
                CopyButton(text: buffer.text)
                    .labelStyle(.iconOnly)
                    .help("Copy logs")
                Button {
                    buffer.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("Clear")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            LogView(buffer: buffer)
        }
        .task(id: StreamKey(service: service, follow: follow, tail: tail, token: reloadToken)) {
            await stream()
        }
    }

    private func stream() async {
        guard let plan = model.plan(role) else { return }
        buffer.clear()
        status = follow ? "Streaming…" : "Loading…"
        let script = RemoteScripts.logs(plan: plan, service: service, tail: tail, follow: follow)
        do {
            for try await chunk in model.ssh.stream(plan.machine, script: script, privileged: true) {
                buffer.append(chunk)
            }
            status = follow ? "Stream ended" : nil
        } catch {
            if !Task.isCancelled {
                buffer.append("\n[\(error.localizedDescription)]\n")
                status = "Error"
            }
        }
    }
}

// MARK: - Files

struct FilesTab: View {
    @Environment(AppModel.self) private var model
    let role: NodeRole
    @State private var selectedPath: String? = "docker-compose.yml"

    var body: some View {
        let files = model.plan(role)?.files ?? []
        HSplitView {
            List(files, selection: $selectedPath) { file in
                HStack {
                    Image(systemName: file.path.hasSuffix(".yml") ? "shippingbox" : "doc.text")
                        .foregroundStyle(.secondary)
                    Text(file.path)
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    if file.isOverridden {
                        Text("Custom")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                .tag(file.path)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            if let file = files.first(where: { $0.path == selectedPath }) {
                VStack(spacing: 0) {
                    HStack {
                        Text(file.path).font(.system(.headline, design: .monospaced))
                        Spacer()
                        if file.isOverridden {
                            Button("Revert to Generated") {
                                model.setOverride(role: role, path: file.path, content: nil)
                            }
                        }
                        CopyButton(text: file.content)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                    CodeEditor(text: Binding(
                        get: { file.content },
                        set: { model.setOverride(role: role, path: file.path, content: $0) }
                    ))
                    // A fresh editor per file, so undo history and the caret never leak across files.
                    .id(file.path)
                    Divider()
                    Text(file.isOverridden
                         ? "This file is customised and no longer follows the Settings tab. Apply Changes to deploy it."
                         : "Generated from the Settings tab. Editing it here creates a custom version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .frame(minWidth: 400)
            } else {
                ContentUnavailableView("Select a File", systemImage: "doc.text")
                    .frame(minWidth: 400)
            }
        }
        #if DEBUG
        // `-BBMCycleFiles YES` flips through every file repeatedly (regression test for editor crashes).
        .task {
            guard UserDefaults.standard.bool(forKey: "BBMCycleFiles") else { return }
            for _ in 0..<3 {
                for path in (model.plan(role)?.files ?? []).map(\.path).reversed() {
                    try? await Task.sleep(for: .milliseconds(400))
                    selectedPath = path
                }
            }
        }
        #endif
    }
}

extension AppModel {
    /// Stores a customised file, or removes the customisation when it matches the generated text.
    func setOverride(role: NodeRole, path: String, content: String?) {
        let generated = plan(role)?.files.first { $0.path == path }?.generated
        let value = (content == generated) ? nil : content
        switch role {
        case .main:
            cluster.main?.fileOverrides[path] = value
        case .worker(let id):
            if let index = cluster.workers.firstIndex(where: { $0.id == id }) {
                cluster.workers[index].fileOverrides[path] = value
            }
        }
    }
}

import BBManagerKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = model.loadError {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .red, text: error)
                }
                if model.cluster.main == nil || model.cluster.workers.isEmpty {
                    GettingStartedCard()
                }
                if model.cluster.main != nil {
                    summaryCards
                    HStack(alignment: .top, spacing: 16) {
                        NodesCard()
                        EndpointsCard()
                    }
                    ChromiumCard()
                    BazelCard()
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("Overview")
        .navigationSubtitle(model.cluster.name)
        .toolbar {
            ToolbarItemGroup {
                if model.allRoles.contains(where: model.hasPendingChanges) {
                    Button {
                        model.applyAllChanges()
                    } label: {
                        Label("Apply Changes", systemImage: "arrow.up.circle")
                    }
                    .help("Deploy configuration changes to every node that has them")
                }
                Button {
                    Task { await model.pollAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh status (⌘R)")
            }
        }
    }

    private var header: some View {
        let summary = model.clusterHealthSummary
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.cluster.name)
                    .font(.largeTitle.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(color: summary.color)
                    Text(summary.label)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summaryCards: some View {
        let scheduler = model.schedulerSummary
        let latest = model.clusterHistory.last
        let onlineMachines = model.machines.filter { model.connectivity[$0.id] == .online }.count
        let runningWorkers = model.cluster.workers.filter { model.health(.worker($0.id)) == .running }.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
            StatCard(
                title: "Workers",
                value: "\(runningWorkers) / \(model.cluster.workers.count)",
                detail: "running",
                symbol: "cpu",
                tint: .blue
            )
            StatCard(
                title: "Executor Slots",
                value: scheduler.map { "\($0.executorSlots)" } ?? "—",
                detail: "configured: \(model.generator.totalExecutorSlots)",
                symbol: "square.grid.3x3.fill",
                tint: .indigo
            )
            StatCard(
                title: "Actions",
                value: Format.rate(latest?.actionsPerSecond),
                detail: scheduler.map { "\($0.executing) executing · \($0.queued) queued" },
                symbol: "bolt.fill",
                tint: .orange
            )
            StatCard(
                title: "Action Cache Hit Rate",
                value: Format.percent(model.frontendSummary?.actionCacheHitRate),
                detail: "since frontend start",
                symbol: "checkmark.seal.fill",
                tint: .green
            )
            StatCard(
                title: "Machines Online",
                value: "\(onlineMachines) / \(model.machines.count)",
                symbol: "network",
                tint: .teal
            )
        }
    }
}

struct GettingStartedCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Get Started", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Add a machine", "Any Linux host you can reach over SSH. BB Manager uses your ~/.ssh/config, keys and agent.",
                     done: !model.machines.isEmpty, action: "Add Machine…") { model.sheet = .addMachine }
                step(2, "Set up the main node", "Runs the frontend, storage, scheduler and portal with Docker Compose.",
                     done: model.cluster.main != nil, action: "Set Up…", enabled: !model.machines.isEmpty) { model.sheet = .setUpMainNode }
                step(3, "Add workers", "Each worker runs bb_worker and bb_runner and executes build actions.",
                     done: !model.cluster.workers.isEmpty, action: "Add Worker…", enabled: model.cluster.main != nil) {
                    model.sheet = .addWorker(preselectedMachine: nil)
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String, done: Bool, action: String, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.18))
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.bold())
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !done {
                Button(action, action: perform)
                    .disabled(!enabled)
            }
        }
    }
}

struct NodesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Nodes", symbol: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 0) {
                if model.cluster.main != nil {
                    row(.main, subtitle: model.mainMachine?.displayName ?? "")
                }
                ForEach(model.cluster.workers) { worker in
                    Divider()
                    row(.worker(worker.id), subtitle: "\(worker.settings.kind.shortLabel) · \(worker.settings.concurrency) slots")
                }
                if model.cluster.workers.isEmpty {
                    Divider()
                    HStack {
                        Text("No workers yet").foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Worker…") { model.sheet = .addWorker(preselectedMachine: nil) }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func row(_ role: NodeRole, subtitle: String) -> some View {
        Button {
            model.selection = role.isMain ? .mainNode : .worker(role.workerID!)
        } label: {
            HStack {
                Image(systemName: role.isMain ? "server.rack" : "cpu")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title(for: role)).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.hasPendingChanges(role) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                        .help("Configuration changes not deployed")
                }
                HealthBadge(health: model.health(role))
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EndpointsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Endpoints", symbol: "link") {
            if let main = model.cluster.main {
                VStack(alignment: .leading, spacing: 10) {
                    endpoint("Remote execution & cache", "grpc://\(main.advertisedAddress):\(main.frontendPort)")
                    endpoint("Worker registration", "\(main.advertisedAddress):\(main.schedulerWorkerPort)")
                    if main.portal.enabled {
                        endpoint("Build event service", "grpc://\(main.advertisedAddress):\(main.portal.besPort)")
                        HStack {
                            endpoint("Portal", "http://\(main.advertisedAddress):\(main.portal.httpPort)")
                            Spacer()
                            if let url = model.portalURL {
                                Link(destination: url) {
                                    Label("Open", systemImage: "safari")
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 380)
    }

    private func endpoint(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}

struct ChromiumCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Use with Chromium", symbol: "globe") {
            if let setup = model.generator.chromiumSetup() {
                Text("Point Siso in a Chromium checkout at this cluster. Its remote actions run on the Linux worker on \(setup.workerMachineName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Snippet(path: ".gclient", note: "Add to the custom_vars of the \"src\" solution.", text: setup.gclientCustomVars)
                Snippet(path: "src/build/config/siso/backend_config/backend.star", note: "Create this file. Buildbarn runs an action only on workers whose platform properties match it exactly.", text: setup.backendStar)
                Snippet(path: "src/build/config/siso/.sisorc", note: "Create this file: the cluster has no TLS or authentication.", text: setup.sisorc)
                Snippet(path: "out/Default/args.gn", note: "Turn on remote execution.", text: setup.argsGN)
                Snippet(path: "In src", note: "Apply the configuration, then build.", text: setup.commands)
            } else {
                Text("Chromium sends its remote actions to Linux workers. Add a worker on a Linux machine to build Chromium with this cluster.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A file or command to copy, with where it goes.
private struct Snippet: View {
    var path: String
    var note: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(path)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                CopyButton(text: text)
                    .controlSize(.small)
            }
            CodeBlock(text: text.trimmingCharacters(in: .newlines))
        }
        .padding(.top, 4)
    }
}

private struct CodeBlock: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct BazelCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let rc = model.generator.bazelrc() {
            Card(title: "Use with Bazel", symbol: "hammer") {
                Text("Add these lines to your project's `.bazelrc`, then build with `bazel build --config=bb //...`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                CodeBlock(text: rc)
                HStack {
                    Spacer()
                    CopyButton(text: rc)
                }
            }
        }
    }
}

import BBManagerKit
import Charts
import SwiftUI

enum StatisticsTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case hosts = "Hosts"
    case explorer = "Metrics Explorer"

    var id: String { rawValue }
}

struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: StatisticsTab = .dashboard

    var body: some View {
        Group {
            if model.cluster.main == nil {
                ContentUnavailableView("No Statistics Yet", systemImage: "chart.xyaxis.line", description: Text("Statistics appear once the main node is deployed."))
            } else {
                switch tab {
                case .dashboard: DashboardTab()
                case .hosts: HostsTab()
                case .explorer: MetricsExplorer()
                }
            }
        }
        .navigationTitle("Statistics")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(StatisticsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
            }
            ToolbarItem {
                Button {
                    Task { await model.pollAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

// MARK: - Dashboard

struct DashboardTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scheduler = model.schedulerSummary
        let frontend = model.frontendSummary
        let latest = model.clusterHistory.last
        let history = model.clusterHistory
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if scheduler == nil && frontend == nil {
                    Banner(symbol: "info.circle.fill", tint: .accentColor, text: "Waiting for metrics from the main node. Metrics are read over SSH from 127.0.0.1 on each machine and need curl or wget there.")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    StatCard(title: "Actions / s", value: Format.rate(latest?.actionsPerSecond, unit: ""), detail: scheduler.map { "\(Format.number($0.tasksScheduled)) scheduled in total" }, symbol: "bolt.fill", tint: .orange)
                    StatCard(title: "Executing", value: scheduler.map { "\($0.executing)" } ?? "—", detail: scheduler.map { "of \($0.executorSlots) executor slots" }, symbol: "gearshape.2.fill", tint: .blue)
                    StatCard(title: "Queued", value: scheduler.map { "\($0.queued)" } ?? "—", detail: "approximate", symbol: "tray.full.fill", tint: .purple)
                    StatCard(title: "Queue Time", value: Format.duration(latest?.queueSeconds ?? scheduler?.averageQueueSeconds), detail: latest?.queueSeconds != nil ? "recent average" : "lifetime average", symbol: "hourglass", tint: .pink)
                    StatCard(title: "Execution Time", value: Format.duration(latest?.executionSeconds ?? scheduler?.averageExecutionSeconds), detail: latest?.executionSeconds != nil ? "recent average" : "lifetime average", symbol: "stopwatch.fill", tint: .teal)
                    StatCard(title: "Action Cache Hits", value: Format.percent(latest?.cacheHitRate ?? frontend?.actionCacheHitRate), detail: frontend.map { "\(Format.number($0.actionCacheHits)) hits · \(Format.number($0.actionCacheMisses)) misses" }, symbol: "checkmark.seal.fill", tint: .green)
                    StatCard(title: "CAS Read", value: latest?.casReadBytesPerSecond.map { Format.bytes($0) + "/s" } ?? "—", detail: frontend.map { "\(Format.bytes($0.chunkBytesRead)) total" }, symbol: "arrow.down.circle.fill", tint: .indigo)
                    StatCard(title: "CAS Written", value: latest?.casWriteBytesPerSecond.map { Format.bytes($0) + "/s" } ?? "—", detail: frontend.map { "\(Format.bytes($0.chunkBytesWritten)) total" }, symbol: "arrow.up.circle.fill", tint: .cyan)
                }

                HStack(alignment: .top, spacing: 14) {
                    ChartCard(title: "Throughput", subtitle: "actions scheduled per second") {
                        Chart(history.filter { $0.actionsPerSecond != nil }) { point in
                            AreaMark(x: .value("Time", point.date), y: .value("Actions/s", point.actionsPerSecond ?? 0))
                                .foregroundStyle(.orange.opacity(0.18))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Time", point.date), y: .value("Actions/s", point.actionsPerSecond ?? 0))
                                .foregroundStyle(.orange)
                                .interpolationMethod(.monotone)
                        }
                    }
                    ChartCard(title: "Load", subtitle: "executing and queued actions") {
                        Chart {
                            ForEach(history) { point in
                                if let executing = point.executing {
                                    LineMark(x: .value("Time", point.date), y: .value("Actions", executing))
                                        .foregroundStyle(by: .value("Series", "Executing"))
                                }
                                if let queued = point.queued {
                                    LineMark(x: .value("Time", point.date), y: .value("Actions", queued))
                                        .foregroundStyle(by: .value("Series", "Queued"))
                                }
                                if let slots = point.executorSlots {
                                    LineMark(x: .value("Time", point.date), y: .value("Actions", slots))
                                        .foregroundStyle(by: .value("Series", "Slots"))
                                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                }
                            }
                        }
                        .chartForegroundStyleScale(["Executing": Color.blue, "Queued": Color.purple, "Slots": Color.secondary])
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    ChartCard(title: "Latency", subtitle: "average queue and execution time") {
                        Chart {
                            ForEach(history) { point in
                                if let queue = point.queueSeconds {
                                    LineMark(x: .value("Time", point.date), y: .value("Seconds", queue))
                                        .foregroundStyle(by: .value("Series", "Queue"))
                                }
                                if let execution = point.executionSeconds {
                                    LineMark(x: .value("Time", point.date), y: .value("Seconds", execution))
                                        .foregroundStyle(by: .value("Series", "Execution"))
                                }
                            }
                        }
                        .chartForegroundStyleScale(["Queue": Color.pink, "Execution": Color.teal])
                    }
                    ChartCard(title: "Action Cache", subtitle: "hit rate per refresh") {
                        Chart(history.filter { $0.cacheHitRate != nil }) { point in
                            LineMark(x: .value("Time", point.date), y: .value("Hit rate", (point.cacheHitRate ?? 0) * 100))
                                .foregroundStyle(.green)
                                .interpolationMethod(.monotone)
                        }
                        .chartYScale(domain: 0...100)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    OutcomesCard(scheduler: scheduler)
                    RequestsCard(frontend: frontend)
                }
                WorkerStagesCard()
                ComponentsCard()
            }
            .padding(20)
        }
    }
}

struct ChartCard<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
                .frame(height: 160)
                .overlay {
                    EmptyChartHint()
                }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// Shown on top of charts until a couple of samples exist.
struct EmptyChartHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.clusterHistory.count < 2 {
            Text("Collecting samples…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct OutcomesCard: View {
    var scheduler: SchedulerSummary?

    var body: some View {
        Card(title: "Action Results", symbol: "checklist") {
            let results = (scheduler?.resultCounts ?? [:]).sorted { $0.value > $1.value }
            if results.isEmpty {
                Text("No completed actions yet.").foregroundStyle(.secondary)
            } else {
                Chart(results, id: \.key) { item in
                    BarMark(x: .value("Count", item.value), y: .value("Result", item.key.isEmpty ? "Unknown" : item.key))
                        .foregroundStyle(by: .value("Result", item.key))
                        .annotation(position: .trailing) {
                            Text(Format.number(item.value)).font(.caption).foregroundStyle(.secondary)
                        }
                }
                .chartLegend(.hidden)
                .frame(height: CGFloat(max(60, results.count * 28)))
            }
            if let dedup = scheduler?.deduplications, !dedup.isEmpty {
                Divider()
                ForEach(dedup.sorted { $0.key < $1.key }, id: \.key) { item in
                    LabeledContent("In-flight deduplication: \(item.key)", value: Format.number(item.value))
                        .font(.callout)
                }
            }
        }
    }
}

struct RequestsCard: View {
    var frontend: FrontendSummary?

    var body: some View {
        Card(title: "Frontend Requests", symbol: "arrow.left.arrow.right") {
            let calls = (frontend?.grpcCalls ?? [:]).sorted { $0.value > $1.value }.prefix(8)
            if calls.isEmpty {
                Text("No gRPC requests recorded yet.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(calls), id: \.key) { item in
                        GridRow {
                            Text(item.key).font(.system(.callout, design: .monospaced))
                            Spacer()
                            Text(Format.number(item.value)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }
}

struct WorkerStagesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let workers = model.cluster.workers.compactMap { worker -> (String, WorkerSummary)? in
            guard let summary = model.workerSummary(worker.id) else { return nil }
            return (model.machine(worker.machineID)?.displayName ?? "Worker", summary)
        }
        if !workers.isEmpty {
            let stages = Array(Set(workers.flatMap { $0.1.stageCounts.keys })).sorted()
            Card(title: "Worker Execution Stages", symbol: "cpu") {
                Text("Average time per stage since each worker started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Worker").foregroundStyle(.secondary)
                        Text("Actions").foregroundStyle(.secondary)
                        ForEach(stages, id: \.self) { Text($0).foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                    Divider()
                    ForEach(workers, id: \.0) { name, summary in
                        GridRow {
                            Text(name).fontWeight(.medium)
                            Text(Format.number(summary.actionsExecuted)).monospacedDigit()
                            ForEach(stages, id: \.self) { stage in
                                Text(Format.duration(summary.averageSeconds(stage: stage))).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ComponentsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.metricsEndpoints.compactMap { endpoint -> (String, ProcessSummary, Double?)? in
            guard let snapshot = model.metrics[endpoint.key] else { return nil }
            let process = ProcessSummary(snapshot)
            let previous = model.previousMetrics[endpoint.key].map(ProcessSummary.init)
            let seconds = model.previousMetrics[endpoint.key].map { snapshot.timestamp.timeIntervalSince($0.timestamp) } ?? 0
            let cpu = counterRate(previous: previous?.cpuSeconds, current: process.cpuSeconds, seconds: seconds)
            return (endpoint.title, process, cpu)
        }
        if !rows.isEmpty {
            Card(title: "Components", symbol: "square.stack.3d.up") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow {
                        Text("Component")
                        Text("CPU")
                        Text("Memory")
                        Text("Goroutines")
                        Text("Uptime")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(rows, id: \.0) { name, process, cpu in
                        GridRow {
                            Text(name).font(.system(.callout, design: .monospaced))
                            Text(cpu.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                            Text(Format.bytes(process.residentMemoryBytes))
                            Text(Format.number(process.goroutines))
                            Text(process.startTime.map { Format.duration(Date().timeIntervalSince($0)) } ?? "—")
                        }
                        .monospacedDigit()
                    }
                }
            }
        }
    }
}

// MARK: - Hosts

struct HostsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], spacing: 14) {
                ForEach(model.machines) { machine in
                    HostCard(machine: machine)
                }
            }
            .padding(20)
        }
    }
}

struct HostCard: View {
    @Environment(AppModel.self) private var model
    var machine: Machine

    var body: some View {
        let sample = model.hostSamples[machine.id]
        let roles = model.roles(on: machine.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusDot(color: (model.connectivity[machine.id] ?? .unknown).color)
                Text(machine.displayName).font(.headline)
                Text(roles.map { $0.isMain ? "Main" : "Worker" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let load = sample?.load1 {
                    Text(String(format: "load %.2f", load))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                MiniGauge(title: "CPU", value: sample?.cpuUsage)
                MiniGauge(title: "Memory", value: sample?.memoryUsage)
                MiniGauge(title: "Disk", value: sample?.diskUsage)
            }
            if let history = model.hostHistory[machine.id], history.count > 1 {
                HostHistoryChart(points: history)
                    .frame(height: 100)
            }
        }
        .padding(16)
        .cardBackground()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.selection = .machine(machine.id) }
    }
}

struct MiniGauge: View {
    var title: String
    var value: Double?

    var body: some View {
        Gauge(value: min(1, max(0, value ?? 0))) {
            Text(title)
        } currentValueLabel: {
            Text(Format.percent(value)).monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(value.map { $0 > 0.9 ? Color.red : $0 > 0.75 ? .orange : .accentColor } ?? .secondary)
        .overlay(alignment: .bottom) {
            Text(title).font(.caption2).foregroundStyle(.secondary).offset(y: 14)
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Explorer

struct MetricsExplorer: View {
    @Environment(AppModel.self) private var model
    @State private var endpoint: MetricsKey?
    @State private var snapshot: MetricsSnapshot?
    @State private var search = ""
    @State private var selectedFamily: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Endpoint", selection: $endpoint) {
                        ForEach(model.metricsEndpoints, id: \.key) { item in
                            Text(item.title).tag(Optional(item.key))
                        }
                    }
                    .labelsHidden()
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Fetch metrics again")
                    .disabled(endpoint == nil || loading)
                }
                .padding(10)
                TextField("Filter", text: $search, prompt: Text("Filter metrics"))
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                Divider()
                List(filteredFamilies, selection: $selectedFamily) { family in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(family.name)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(family.type.rawValue) · \(family.samples.count) series")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(family.name)
                }
                .overlay {
                    if loading {
                        ProgressView()
                    } else if let error {
                        ContentUnavailableView("Could Not Load Metrics", systemImage: "exclamationmark.triangle", description: Text(error))
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)

            Group {
                if let family = selectedFamily.flatMap({ snapshot?.families[$0] }) {
                    FamilyDetail(family: family)
                } else {
                    ContentUnavailableView("Select a Metric", systemImage: "chart.bar.doc.horizontal", description: Text("\(snapshot?.families.count ?? 0) metric families"))
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if endpoint == nil { endpoint = model.metricsEndpoints.first?.key }
        }
        .task(id: endpoint) { await load() }
    }

    private var filteredFamilies: [MetricFamily] {
        let families = snapshot?.sortedFamilies ?? []
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return families }
        return families.filter { $0.name.lowercased().contains(query) || $0.help.lowercased().contains(query) }
    }

    private func load() async {
        guard let endpoint else { return }
        loading = true
        error = nil
        do {
            snapshot = try await model.fetchFullMetrics(role: endpoint.role, service: endpoint.service)
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
                snapshot = nil
            }
        }
        loading = false
    }
}

struct FamilyDetail: View {
    var family: MetricFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(family.name)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                HStack {
                    Text(family.type.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                    Text("\(family.samples.count) samples").font(.caption).foregroundStyle(.secondary)
                }
                if !family.help.isEmpty {
                    Text(family.help).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            Table(family.samples.enumerated().map { IndexedSample(index: $0.offset, sample: $0.element) }) {
                TableColumn("Series") { row in
                    Text(row.sample.name + row.sample.labelDescription)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .help(row.sample.labelDescription)
                }
                TableColumn("Value") { row in
                    Text(Format.number(row.sample.value))
                        .monospacedDigit()
                        .help(String(row.sample.value))
                }
                .width(min: 80, ideal: 100, max: 160)
            }
        }
    }
}

struct IndexedSample: Identifiable {
    var index: Int
    var sample: MetricSample
    var id: Int { index }
}

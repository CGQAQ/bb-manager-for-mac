import Foundation

// MARK: - Poll output

/// Splits the output of `RemoteScripts.poll` into its `@@` sections.
public struct PollOutput: Sendable {
    public var sections: [String: String]

    public init(_ text: String) {
        var sections: [String: String] = [:]
        var current: String?
        var buffer: [Substring] = []
        func flush() {
            if let current { sections[current] = buffer.joined(separator: "\n") }
            buffer.removeAll(keepingCapacity: true)
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                flush()
                current = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if current != nil {
                buffer.append(line)
            }
        }
        flush()
        self.sections = sections
    }

    public subscript(_ name: String) -> String? { sections[name] }

    public func host(previousCPU: CPUCounters?) -> HostSample {
        HostSample(
            loadavg: self["loadavg"] ?? "",
            stat: self["stat"] ?? "",
            meminfo: self["meminfo"] ?? "",
            disk: self["disk"] ?? "",
            cpuPercent: self["cpupercent"],
            previousCPU: previousCPU
        )
    }

    public var dockerStats: [ContainerUsage] { ContainerUsage.parse(self["dockerstats"] ?? "") }

    /// Buildbarn Compose projects running on the machine, including ones BB Manager didn't create.
    /// Nil when the section is missing (for example an older script or no Docker access).
    public var buildbarnProjects: [ComposeProject]? {
        guard let text = self["projects"] else { return nil }
        return ComposeProject.parse(text)
    }

    public func containers(nodeKey: String) -> [ContainerStatus]? {
        guard let text = self["compose \(nodeKey)"] else { return nil }
        return ContainerStatus.parse(text)
    }

    public func metrics(nodeKey: String, service: String, timestamp: Date = Date()) -> MetricsSnapshot? {
        guard let text = self["metrics \(nodeKey) \(service)"],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PrometheusParser.parse(text, timestamp: timestamp)
    }
}

// MARK: - Host sample

public struct CPUCounters: Sendable, Hashable {
    public var total: Double
    public var idle: Double
}

public struct HostSample: Sendable {
    public var timestamp: Date
    public var load1: Double?
    public var load5: Double?
    public var load15: Double?
    public var cpu: CPUCounters?
    /// 0...1, available once two samples exist.
    public var cpuUsage: Double?
    public var memoryTotal: Int64?
    public var memoryAvailable: Int64?
    public var diskTotal: Int64?
    public var diskAvailable: Int64?

    public var memoryUsage: Double? {
        guard let total = memoryTotal, let available = memoryAvailable, total > 0 else { return nil }
        return Double(total - available) / Double(total)
    }

    public var diskUsage: Double? {
        guard let total = diskTotal, let available = diskAvailable, total > 0 else { return nil }
        return Double(total - available) / Double(total)
    }

    public init(loadavg: String, stat: String, meminfo: String, disk: String, cpuPercent: String? = nil, previousCPU: CPUCounters?, timestamp: Date = Date()) {
        self.timestamp = timestamp
        // macOS has no /proc/stat; the poll script reports a percentage directly.
        if let cpuPercent, let percent = Double(cpuPercent.trimmingCharacters(in: .whitespacesAndNewlines)) {
            cpuUsage = min(1, max(0, percent / 100))
        }
        let load = loadavg.split(separator: " ").compactMap { Double($0) }
        if load.count >= 3 {
            load1 = load[0]; load5 = load[1]; load15 = load[2]
        }
        let fields = stat.split(separator: " ").dropFirst().compactMap { Double($0) }
        if fields.count >= 4 {
            let idle = fields[3] + (fields.count > 4 ? fields[4] : 0)
            let total = fields.prefix(8).reduce(0, +)
            let counters = CPUCounters(total: total, idle: idle)
            cpu = counters
            if let previousCPU, total > previousCPU.total {
                let dTotal = total - previousCPU.total
                let dIdle = idle - previousCPU.idle
                cpuUsage = min(1, max(0, 1 - dIdle / dTotal))
            }
        }
        for line in meminfo.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let kb = Int64(parts[1]) else { continue }
            if parts[0] == "MemTotal:" { memoryTotal = kb * 1024 }
            if parts[0] == "MemAvailable:" { memoryAvailable = kb * 1024 }
        }
        let df = disk.split(separator: " ", omittingEmptySubsequences: true)
        if df.count >= 4, let total = Int64(df[1]), let available = Int64(df[3]) {
            diskTotal = total * 1024
            diskAvailable = available * 1024
        }
    }
}

// MARK: - Containers

/// One entry of `docker compose ps --format json`.
public struct ContainerStatus: Identifiable, Hashable, Sendable, Decodable {
    public struct Publisher: Hashable, Sendable, Decodable {
        public var url: String?
        public var targetPort: Int?
        public var publishedPort: Int?
        public var proto: String?

        enum CodingKeys: String, CodingKey {
            case url = "URL", targetPort = "TargetPort", publishedPort = "PublishedPort", proto = "Protocol"
        }
    }

    public var name: String
    public var service: String
    public var state: String
    public var status: String
    public var health: String?
    public var image: String
    public var exitCode: Int?
    public var publishers: [Publisher]?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "Name", service = "Service", state = "State", status = "Status"
        case health = "Health", image = "Image", exitCode = "ExitCode", publishers = "Publishers"
    }

    public init(name: String, service: String, state: String, status: String, health: String? = nil, image: String, exitCode: Int? = nil, publishers: [Publisher]? = nil) {
        self.name = name
        self.service = service
        self.state = state
        self.status = status
        self.health = health
        self.image = image
        self.exitCode = exitCode
        self.publishers = publishers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        service = try c.decodeIfPresent(String.self, forKey: .service) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        health = try c.decodeIfPresent(String.self, forKey: .health)
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        publishers = try? c.decodeIfPresent([Publisher].self, forKey: .publishers)
    }

    public var isRunning: Bool { state.lowercased() == "running" }

    /// One-shot helpers that are expected to exit.
    public var isOneShot: Bool { service.contains("installer") }

    public var publishedPorts: String {
        let ports = (publishers ?? [])
            .compactMap { p -> String? in
                guard let published = p.publishedPort, published != 0, let target = p.targetPort else { return nil }
                let host = (p.url == nil || p.url == "0.0.0.0" || p.url == "::") ? "" : "\(p.url!):"
                return "\(host)\(published)→\(target)"
            }
        return Array(Set(ports)).sorted().joined(separator: ", ")
    }

    /// Accepts both the JSON array (older Compose) and JSON lines (Compose ≥ 2.21) formats.
    public static func parse(_ text: String) -> [ContainerStatus] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let decoder = JSONDecoder()
        if trimmed.hasPrefix("["), let list = try? decoder.decode([ContainerStatus].self, from: Data(trimmed.utf8)) {
            return list.sorted { $0.service < $1.service }
        }
        return trimmed.split(separator: "\n")
            .compactMap { try? decoder.decode(ContainerStatus.self, from: Data($0.utf8)) }
            .sorted { $0.service < $1.service }
    }
}

/// A Docker Compose project that runs Buildbarn images, found with `docker ps`.
public struct ComposeProject: Identifiable, Hashable, Sendable {
    public struct Container: Hashable, Sendable {
        public var service: String
        public var image: String
        public var state: String
        public var ports: String

        public var isRunning: Bool { state.lowercased() == "running" }
    }

    public var name: String
    public var workingDirectory: String
    /// Compose files the project was started with (absolute paths).
    public var composeFiles: [String] = []
    public var containers: [Container]

    public var id: String { name }

    /// Fields separated by `|`: project, working dir, service, image, state, ports, compose files.
    public static let psFormat = "{{.Label \"com.docker.compose.project\"}}|{{.Label \"com.docker.compose.project.working_dir\"}}|{{.Label \"com.docker.compose.service\"}}|{{.Image}}|{{.State}}|{{.Ports}}|{{.Label \"com.docker.compose.project.config_files\"}}"

    public var runningCount: Int { containers.filter(\.isRunning).count }

    /// Host ports published by the project's containers (any bind address).
    public var hostPorts: Set<Int> {
        Set(containers.flatMap { Self.hostPorts(in: $0.ports) })
    }

    /// Parses `docker ps` port strings such as `0.0.0.0:8980->8980/tcp, [::]:8980->8980/tcp`
    /// or `0.0.0.0:9000-9002->9000-9002/tcp`. Exposed-only ports (`8981/tcp`) are ignored.
    public static func hostPorts(in text: String) -> [Int] {
        var ports: [Int] = []
        let pattern = #/:(\d+)(?:-(\d+))?->/#
        for match in text.matches(of: pattern) {
            guard let start = Int(match.1) else { continue }
            let end = match.2.flatMap { Int($0) } ?? start
            if end >= start && end - start < 1000 {
                ports.append(contentsOf: start...end)
            }
        }
        return ports
    }

    /// Groups `docker ps` lines by project and keeps projects that run a Buildbarn image.
    public static func parse(_ text: String) -> [ComposeProject] {
        var order: [String] = []
        var directories: [String: String] = [:]
        var files: [String: [String]] = [:]
        var containers: [String: [Container]] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, !fields[0].isEmpty else { continue }
            let name = fields[0]
            if containers[name] == nil {
                order.append(name)
                directories[name] = fields[1]
            }
            if fields.count > 6, files[name, default: []].isEmpty {
                files[name] = fields[6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            containers[name, default: []].append(Container(
                service: fields[2],
                image: fields[3],
                state: fields[4],
                ports: fields.count > 5 ? fields[5] : ""
            ))
        }
        return order.compactMap { name in
            let list = containers[name] ?? []
            guard list.contains(where: { $0.image.contains("buildbarn/") }) else { return nil }
            return ComposeProject(
                name: name,
                workingDirectory: directories[name] ?? "",
                composeFiles: files[name] ?? [],
                containers: list.sorted { $0.service < $1.service }
            )
        }
    }
}

/// One entry of `docker stats --no-stream --format '{{json .}}'`.
public struct ContainerUsage: Hashable, Sendable, Identifiable {
    public var name: String
    public var cpuPercent: Double
    public var memoryPercent: Double
    public var memoryUsage: String

    public var id: String { name }

    public static func parse(_ text: String) -> [ContainerUsage] {
        text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = object["Name"] as? String else { return nil }
            func percent(_ key: String) -> Double {
                Double((object[key] as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? 0
            }
            return ContainerUsage(
                name: name,
                cpuPercent: percent("CPUPerc"),
                memoryPercent: percent("MemPerc"),
                memoryUsage: (object["MemUsage"] as? String ?? "").components(separatedBy: " / ").first ?? ""
            )
        }
    }
}

// MARK: - Buildbarn summaries

/// Counters extracted from bb_scheduler's in-memory build queue metrics.
public struct SchedulerSummary: Sendable {
    static let prefix = "buildbarn_builder_in_memory_build_queue_"

    public var timestamp: Date
    public var workersCreated: Double
    public var workersRemoved: Double
    public var tasksScheduled: Double
    public var tasksStarted: Double
    public var queuedSecondsSum: Double
    public var tasksCompleted: Double
    public var executingSecondsSum: Double
    public var resultCounts: [String: Double]
    public var deduplications: [String: Double]
    public var platforms: Set<String>

    public init?(_ snapshot: MetricsSnapshot) {
        let p = Self.prefix
        guard snapshot.families.keys.contains(where: { $0.hasPrefix(p) }) else { return nil }
        timestamp = snapshot.timestamp
        workersCreated = snapshot.sum(p + "workers_created_total") ?? 0
        workersRemoved = snapshot.sum(p + "workers_removed_total") ?? 0
        tasksScheduled = snapshot.sum(p + "tasks_scheduled_total") ?? 0
        tasksStarted = snapshot.sum(p + "tasks_queued_duration_seconds_count") ?? 0
        queuedSecondsSum = snapshot.sum(p + "tasks_queued_duration_seconds_sum") ?? 0
        tasksCompleted = snapshot.sum(p + "tasks_executing_duration_seconds_count") ?? 0
        executingSecondsSum = snapshot.sum(p + "tasks_executing_duration_seconds_sum") ?? 0
        resultCounts = snapshot.sum(p + "tasks_executing_duration_seconds_count", groupedBy: "result")
        deduplications = snapshot.sum(p + "in_flight_deduplications_total", groupedBy: "outcome")
        platforms = Set(snapshot.samples(p + "workers_created_total").compactMap { $0.labels["platform"] })
    }

    /// Worker threads currently registered (each unit of concurrency registers separately).
    public var executorSlots: Int { max(0, Int(workersCreated - workersRemoved)) }

    /// Approximate number of tasks waiting for a worker.
    public var queued: Int { max(0, Int(tasksScheduled - tasksStarted)) }

    /// Approximate number of tasks currently executing.
    public var executing: Int { max(0, Int(tasksStarted - tasksCompleted)) }

    public var averageQueueSeconds: Double? { tasksStarted > 0 ? queuedSecondsSum / tasksStarted : nil }
    public var averageExecutionSeconds: Double? { tasksCompleted > 0 ? executingSecondsSum / tasksCompleted : nil }
}

/// Request statistics from bb_storage running as frontend.
public struct FrontendSummary: Sendable {
    public var timestamp: Date
    public var actionCacheHits: Double
    public var actionCacheMisses: Double
    public var chunkBytesRead: Double
    public var chunkBytesWritten: Double
    public var grpcCalls: [String: Double]

    static let duration = "buildbarn_blobstore_blob_access_operations_duration_seconds_count"
    static let blobSize = "buildbarn_blobstore_blob_access_operations_blob_size_bytes_sum"

    public init?(_ snapshot: MetricsSnapshot) {
        timestamp = snapshot.timestamp
        let acGets = snapshot.samples(Self.duration).filter {
            $0.labels["operation"] == "Get" && ($0.labels["storage_type"] ?? "").uppercased().hasPrefix("AC")
        }
        // Each decorator in a blobstore chain reports separately. The outermost one
        // sees every request, so use the backend type with the largest total.
        let byBackend = Dictionary(grouping: acGets) { $0.labels["backend_type"] ?? "" }
        let outer = byBackend.max { a, b in a.value.reduce(0) { $0 + $1.value } < b.value.reduce(0) { $0 + $1.value } }
        actionCacheHits = outer?.value.filter { $0.labels["grpc_code"] == "OK" }.reduce(0) { $0 + $1.value } ?? 0
        actionCacheMisses = outer?.value.filter { $0.labels["grpc_code"] == "NotFound" }.reduce(0) { $0 + $1.value } ?? 0

        let chunkSizes = snapshot.samples(Self.blobSize).filter { ($0.labels["storage_type"] ?? "").uppercased() == "CS" }
        let chunkByBackend = Dictionary(grouping: chunkSizes) { $0.labels["backend_type"] ?? "" }
        let chunkOuter = chunkByBackend.max { a, b in a.value.reduce(0) { $0 + $1.value } < b.value.reduce(0) { $0 + $1.value } }
        chunkBytesRead = chunkOuter?.value.filter { $0.labels["operation"] == "Get" }.reduce(0) { $0 + $1.value } ?? 0
        chunkBytesWritten = chunkOuter?.value.filter { $0.labels["operation"] == "Put" }.reduce(0) { $0 + $1.value } ?? 0

        var calls: [String: Double] = [:]
        for sample in snapshot.samples("grpc_server_handled_total") {
            let service = (sample.labels["grpc_service"] ?? "").split(separator: ".").last.map(String.init) ?? ""
            let method = sample.labels["grpc_method"] ?? "?"
            calls["\(service).\(method)", default: 0] += sample.value
        }
        grpcCalls = calls
        if acGets.isEmpty && chunkSizes.isEmpty && calls.isEmpty { return nil }
    }

    public var actionCacheHitRate: Double? {
        let total = actionCacheHits + actionCacheMisses
        return total > 0 ? actionCacheHits / total : nil
    }
}

/// Per-stage execution statistics from bb_worker.
public struct WorkerSummary: Sendable {
    public var timestamp: Date
    public var stageSeconds: [String: Double]
    public var stageCounts: [String: Double]
    public var results: [String: Double]

    static let name = "buildbarn_builder_build_executor_duration_seconds"

    public init?(_ snapshot: MetricsSnapshot) {
        timestamp = snapshot.timestamp
        stageSeconds = snapshot.sum(Self.name + "_sum", groupedBy: "stage")
        stageCounts = snapshot.sum(Self.name + "_count", groupedBy: "stage")
        guard !stageCounts.isEmpty else { return nil }
        let maxStage = stageCounts.max { $0.value < $1.value }?.key
        results = snapshot.sum(Self.name + "_count", groupedBy: "result") { $0["stage"] == maxStage }
    }

    /// Actions that went through the worker (count of the busiest stage).
    public var actionsExecuted: Double { stageCounts.values.max() ?? 0 }

    public func averageSeconds(stage: String) -> Double? {
        guard let count = stageCounts[stage], count > 0 else { return nil }
        return (stageSeconds[stage] ?? 0) / count
    }
}

/// Go runtime statistics every Buildbarn component exports.
public struct ProcessSummary: Sendable {
    public var residentMemoryBytes: Double?
    public var cpuSeconds: Double?
    public var goroutines: Double?
    public var startTime: Date?

    public init(_ snapshot: MetricsSnapshot) {
        residentMemoryBytes = snapshot.sum("process_resident_memory_bytes")
        cpuSeconds = snapshot.sum("process_cpu_seconds_total")
        goroutines = snapshot.sum("go_goroutines")
        startTime = snapshot.sum("process_start_time_seconds").map { Date(timeIntervalSince1970: $0) }
    }
}

/// Rate of change of a monotonically increasing counter, tolerating restarts.
public func counterRate(previous: Double?, current: Double?, seconds: Double) -> Double? {
    guard let previous, let current, seconds > 0 else { return nil }
    let delta = current >= previous ? current - previous : current
    return delta / seconds
}

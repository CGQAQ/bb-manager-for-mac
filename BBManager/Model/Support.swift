import BBManagerKit
import Foundation
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case mainNode
    case workers
    case statistics
    case configuration
    case worker(UUID)
    case machine(UUID)
}

enum ActiveSheet: Identifiable {
    case addMachine
    case editMachine(UUID)
    case setUpMainNode
    case addWorker(preselectedMachine: UUID?)
    case removeNode(NodeRole)

    var id: String {
        switch self {
        case .addMachine: "addMachine"
        case .editMachine(let id): "edit-\(id)"
        case .setUpMainNode: "setUpMain"
        case .addWorker: "addWorker"
        case .removeNode(let role): "remove-\(role)"
        }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum Connectivity: Equatable {
    case unknown
    case checking
    case online
    case offline(String)

    var color: Color {
        switch self {
        case .unknown: .secondary
        case .checking: .yellow
        case .online: .green
        case .offline: .red
        }
    }

    var label: String {
        switch self {
        case .unknown: "Not checked"
        case .checking: "Connecting…"
        case .online: "Online"
        case .offline: "Unreachable"
        }
    }
}

enum NodeHealth: Equatable {
    case notDeployed
    case unknown
    case running
    case degraded(running: Int, total: Int)
    case stopped
    case unreachable

    var color: Color {
        switch self {
        case .notDeployed, .unknown: .secondary
        case .running: .green
        case .degraded: .orange
        case .stopped, .unreachable: .red
        }
    }

    var label: String {
        switch self {
        case .notDeployed: "Not deployed"
        case .unknown: "Checking…"
        case .running: "Running"
        case .degraded(let running, let total): "\(running) of \(total) running"
        case .stopped: "Stopped"
        case .unreachable: "Unreachable"
        }
    }

    var symbol: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .stopped, .unreachable: "xmark.octagon.fill"
        case .notDeployed: "circle.dashed"
        case .unknown: "ellipsis.circle"
        }
    }
}

struct NodeRuntime {
    var containers: [ContainerStatus] = []
    var lastUpdated: Date?
    var error: String?
}

struct MetricsKey: Hashable {
    var role: NodeRole
    var service: String
}

struct HostPoint: Identifiable {
    let id = UUID()
    var date: Date
    var cpu: Double?
    var memory: Double?
    var load1: Double?
}

struct ClusterPoint: Identifiable {
    let id = UUID()
    var date: Date
    var actionsPerSecond: Double?
    var queued: Int?
    var executing: Int?
    var executorSlots: Int?
    var queueSeconds: Double?
    var executionSeconds: Double?
    var cacheHitRate: Double?
    var casReadBytesPerSecond: Double?
    var casWriteBytesPerSecond: Double?
}

/// Append-only text buffer for live logs; views append incrementally.
@MainActor @Observable
final class LogBuffer {
    private(set) var chunks: [String] = []
    /// Changes whenever existing content is removed, so views know to reload.
    private(set) var generation = 0
    private var characterCount = 0
    var limit = 4_000_000

    func append(_ raw: String) {
        let text = Self.clean(raw)
        guard !text.isEmpty else { return }
        chunks.append(text)
        characterCount += text.count
        if characterCount > limit {
            let keep = chunks.count / 2
            chunks = Array(chunks.suffix(keep))
            characterCount = chunks.reduce(0) { $0 + $1.count }
            generation += 1
        }
    }

    /// Drops ANSI escape sequences and turns carriage returns into newlines.
    static func clean(_ text: String) -> String {
        var result = text
        if result.contains("\u{1B}") {
            result = result.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
        if result.contains("\r") {
            result = result.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return result
    }

    func clear() {
        chunks.removeAll()
        characterCount = 0
        generation += 1
    }

    var text: String { chunks.joined() }
}

/// A long-running remote command whose output is shown in the console sheet.
@MainActor @Observable
final class OperationSession: Identifiable {
    enum State: Equatable {
        case running
        case succeeded
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let title: String
    let machineName: String
    let startedAt = Date()
    var state: State = .running
    let log = LogBuffer()
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, machineName: String) {
        self.title = title
        self.machineName = machineName
    }

    var isRunning: Bool { state == .running }

    func cancel() {
        task?.cancel()
    }
}

enum AppDefaults {
    static let refreshInterval = "refreshInterval"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let sshPath = "sshPath"
    static let sshConnectTimeout = "sshConnectTimeout"
    static let sshExtraOptions = "sshExtraOptions"
    static let historyMinutes = "historyMinutes"

    static func register() {
        UserDefaults.standard.register(defaults: [
            refreshInterval: 10.0,
            showMenuBarExtra: true,
            sshPath: "/usr/bin/ssh",
            sshConnectTimeout: 10,
            sshExtraOptions: "",
            historyMinutes: 30,
        ])
    }
}

import Foundation

/// A cluster and the machines it runs on. Each profile has its own machines, so
/// switching profiles switches what BB Manager shows, polls and deploys; it never
/// changes what runs on the machines. The profile's name is its cluster's name.
public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var machines: [Machine]
    public var cluster: ClusterConfiguration

    public init(id: UUID = UUID(), machines: [Machine] = [], cluster: ClusterConfiguration = ClusterConfiguration()) {
        self.id = id
        self.machines = machines
        self.cluster = cluster
    }

    public var name: String { cluster.name }

    /// A copy under a new name. Its machines get new IDs, so their Keychain passwords
    /// and settings are its own; `machineIDs` maps each old ID to its new one.
    public func duplicated(name: String) -> (profile: Profile, machineIDs: [UUID: UUID]) {
        var map: [UUID: UUID] = [:]
        var copy = Profile(machines: machines, cluster: cluster)
        for index in copy.machines.indices {
            let newID = UUID()
            map[copy.machines[index].id] = newID
            copy.machines[index].id = newID
        }
        if let id = copy.cluster.main?.machineID, let newID = map[id] {
            copy.cluster.main?.machineID = newID
        }
        for index in copy.cluster.workers.indices {
            if let newID = map[copy.cluster.workers[index].machineID] {
                copy.cluster.workers[index].machineID = newID
            }
        }
        copy.cluster.name = name
        return (copy, map)
    }

    /// `base`, or `base 2`, `base 3`… whichever no profile in `profiles` uses yet.
    public static func uniqueName(_ base: String, among profiles: [Profile]) -> String {
        let taken = Set(profiles.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}

/// Everything BB Manager remembers between launches (passwords live in the Keychain).
public struct PersistedState: Codable, Sendable {
    public var version = 2
    public var profiles: [Profile]
    public var activeProfileID: UUID

    public init(profiles: [Profile], activeProfileID: UUID? = nil) {
        let profiles = profiles.isEmpty ? [Profile()] : profiles
        self.profiles = profiles
        self.activeProfileID = activeProfileID.flatMap { id in profiles.contains { $0.id == id } ? id : nil } ?? profiles[0].id
    }

    /// A state with a single profile.
    public init(machines: [Machine] = [], cluster: ClusterConfiguration = ClusterConfiguration()) {
        self.init(profiles: [Profile(machines: machines, cluster: cluster)])
    }

    public var activeProfile: Profile {
        get { profiles.first { $0.id == activeProfileID } ?? profiles[0] }
        set {
            if let index = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[index] = newValue
            } else {
                profiles.append(newValue)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, profiles, activeProfileID, machines, cluster
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let profiles = try container.decodeIfPresent([Profile].self, forKey: .profiles), !profiles.isEmpty {
            self.init(profiles: profiles, activeProfileID: try container.decodeIfPresent(UUID.self, forKey: .activeProfileID))
        } else {
            // Version 1 kept one cluster and its machines at the top level.
            self.init(
                machines: try container.decodeIfPresent([Machine].self, forKey: .machines) ?? [],
                cluster: try container.decodeIfPresent(ClusterConfiguration.self, forKey: .cluster) ?? ClusterConfiguration()
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(activeProfileID, forKey: .activeProfileID)
        // Also written the version 1 way, so an earlier BB Manager still opens the
        // active profile instead of starting empty.
        try container.encode(activeProfile.machines, forKey: .machines)
        try container.encode(activeProfile.cluster, forKey: .cluster)
    }
}

public struct StateStore: Sendable {
    public var url: URL

    public init(url: URL = StateStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BB Manager", isDirectory: true).appendingPathComponent("state.json")
    }

    public func load() throws -> PersistedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return PersistedState() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedState.self, from: data)
    }

    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }
}

// MARK: - Formatting

public enum Format {
    public static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    public static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return bytes(Int64(value))
    }

    public static func percent(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f%%", value * 100)
    }

    public static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        if seconds < 0.001 { return String(format: "%.0f µs", seconds * 1_000_000) }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        if seconds < 3600 { return String(format: "%.0f min %.0f s", (seconds / 60).rounded(.down), seconds.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%.1f h", seconds / 3600)
    }

    public static func rate(_ perSecond: Double?, unit: String = "/s") -> String {
        guard let perSecond, perSecond.isFinite else { return "—" }
        if perSecond >= 100 { return String(format: "%.0f\(unit)", perSecond) }
        if perSecond >= 10 { return String(format: "%.1f\(unit)", perSecond) }
        return String(format: "%.2f\(unit)", perSecond)
    }

    public static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if abs(value) >= 1_000_000_000 { return String(format: "%.2fG", value / 1_000_000_000) }
        if abs(value) >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
        if abs(value) >= 10_000 { return String(format: "%.1fk", value / 1000) }
        if value == value.rounded() { return String(format: "%.0f", value) }
        return String(format: "%.3g", value)
    }

    /// `ghcr.io/buildbarn/bb-storage:2026…` → `bb-storage:2026…`
    public static func shortImage(_ image: String) -> String {
        let withoutDigest = image.components(separatedBy: "@").first ?? image
        return withoutDigest.split(separator: "/").last.map(String.init) ?? image
    }
}

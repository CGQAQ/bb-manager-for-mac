import Foundation

/// Everything BB Manager remembers between launches (passwords live in the Keychain).
public struct PersistedState: Codable, Sendable {
    public var version: Int = 1
    public var machines: [Machine] = []
    public var cluster = ClusterConfiguration()

    public init(machines: [Machine] = [], cluster: ClusterConfiguration = ClusterConfiguration()) {
        self.machines = machines
        self.cluster = cluster
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

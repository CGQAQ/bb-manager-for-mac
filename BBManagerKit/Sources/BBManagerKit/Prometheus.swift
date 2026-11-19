import Foundation

public enum MetricType: String, Sendable, CaseIterable {
    case counter, gauge, histogram, summary, untyped
}

public struct MetricSample: Hashable, Sendable {
    public var name: String
    public var labels: [String: String]
    public var value: Double

    public init(name: String, labels: [String: String], value: Double) {
        self.name = name
        self.labels = labels
        self.value = value
    }

    /// `{a="1", b="2"}` with keys sorted, or an empty string.
    public var labelDescription: String {
        guard !labels.isEmpty else { return "" }
        let parts = labels.keys.sorted().map { "\($0)=\"\(labels[$0]!)\"" }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}

public struct MetricFamily: Sendable, Identifiable {
    public var name: String
    public var type: MetricType
    public var help: String
    public var samples: [MetricSample]

    public var id: String { name }
}

public struct MetricsSnapshot: Sendable {
    public var families: [String: MetricFamily]
    public var timestamp: Date

    public init(families: [String: MetricFamily] = [:], timestamp: Date = Date()) {
        self.families = families
        self.timestamp = timestamp
    }

    public var isEmpty: Bool { families.isEmpty }

    public var sortedFamilies: [MetricFamily] { families.values.sorted { $0.name < $1.name } }

    /// All samples with exactly this sample name (e.g. `foo_count`), across families.
    public func samples(_ sampleName: String) -> [MetricSample] {
        if let family = families[sampleName] {
            let exact = family.samples.filter { $0.name == sampleName }
            if !exact.isEmpty { return exact }
        }
        for suffix in ["_count", "_sum", "_bucket", "_total"] where sampleName.hasSuffix(suffix) {
            let base = String(sampleName.dropLast(suffix.count))
            if let family = families[base] {
                return family.samples.filter { $0.name == sampleName }
            }
        }
        return []
    }

    /// Sum of all samples with this name whose labels match the predicate, or nil if absent.
    public func sum(_ sampleName: String, where predicate: ([String: String]) -> Bool = { _ in true }) -> Double? {
        let matching = samples(sampleName).filter { predicate($0.labels) && $0.value.isFinite }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0) { $0 + $1.value }
    }

    /// Sums grouped by the value of one label.
    public func sum(_ sampleName: String, groupedBy label: String, where predicate: ([String: String]) -> Bool = { _ in true }) -> [String: Double] {
        var result: [String: Double] = [:]
        for sample in samples(sampleName) where predicate(sample.labels) && sample.value.isFinite {
            result[sample.labels[label] ?? "", default: 0] += sample.value
        }
        return result
    }
}

/// Parser for the Prometheus text exposition format (version 0.0.4).
public enum PrometheusParser {
    public static func parse(_ text: String, timestamp: Date = Date()) -> MetricsSnapshot {
        var families: [String: MetricFamily] = [:]

        func family(for sampleName: String) -> String {
            if families[sampleName] != nil { return sampleName }
            for suffix in ["_bucket", "_count", "_sum", "_created"] where sampleName.hasSuffix(suffix) {
                let base = String(sampleName.dropLast(suffix.count))
                if let existing = families[base], existing.type == .histogram || existing.type == .summary {
                    return base
                }
            }
            return sampleName
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if line.isEmpty { continue }
            if line.first == "#" {
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count >= 3 else { continue }
                let name = String(parts[2])
                if parts[1] == "HELP" {
                    let help = parts.count > 3 ? unescapeHelp(String(parts[3])) : ""
                    families[name, default: MetricFamily(name: name, type: .untyped, help: "", samples: [])].help = help
                } else if parts[1] == "TYPE", parts.count > 3 {
                    let type = MetricType(rawValue: String(parts[3]).trimmingCharacters(in: .whitespaces)) ?? .untyped
                    families[name, default: MetricFamily(name: name, type: type, help: "", samples: [])].type = type
                }
                continue
            }
            guard let sample = parseSample(line) else { continue }
            let familyName = family(for: sample.name)
            families[familyName, default: MetricFamily(name: familyName, type: .untyped, help: "", samples: [])]
                .samples.append(sample)
        }
        families = families.filter { !$0.value.samples.isEmpty }
        return MetricsSnapshot(families: families, timestamp: timestamp)
    }

    static func parseSample(_ line: Substring) -> MetricSample? {
        let chars = Array(line.utf8)
        var i = 0
        // Metric name.
        while i < chars.count, chars[i] != UInt8(ascii: "{"), chars[i] != UInt8(ascii: " "), chars[i] != UInt8(ascii: "\t") {
            i += 1
        }
        guard i > 0 else { return nil }
        let name = String(decoding: chars[0..<i], as: UTF8.self)
        var labels: [String: String] = [:]

        if i < chars.count, chars[i] == UInt8(ascii: "{") {
            i += 1
            while i < chars.count {
                while i < chars.count, chars[i] == UInt8(ascii: " ") || chars[i] == UInt8(ascii: ",") { i += 1 }
                if i < chars.count, chars[i] == UInt8(ascii: "}") { i += 1; break }
                let keyStart = i
                while i < chars.count, chars[i] != UInt8(ascii: "=") { i += 1 }
                guard i < chars.count else { return nil }
                let key = String(decoding: chars[keyStart..<i], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                i += 1
                guard i < chars.count, chars[i] == UInt8(ascii: "\"") else { return nil }
                i += 1
                var value: [UInt8] = []
                while i < chars.count, chars[i] != UInt8(ascii: "\"") {
                    if chars[i] == UInt8(ascii: "\\"), i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case UInt8(ascii: "n"): value.append(UInt8(ascii: "\n"))
                        default: value.append(chars[i])
                        }
                    } else {
                        value.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { return nil }
                i += 1
                labels[key] = String(decoding: value, as: UTF8.self)
            }
        }

        while i < chars.count, chars[i] == UInt8(ascii: " ") || chars[i] == UInt8(ascii: "\t") { i += 1 }
        let valueStart = i
        while i < chars.count, chars[i] != UInt8(ascii: " "), chars[i] != UInt8(ascii: "\t") { i += 1 }
        guard valueStart < i else { return nil }
        let valueText = String(decoding: chars[valueStart..<i], as: UTF8.self)
        guard let value = parseValue(valueText) else { return nil }
        return MetricSample(name: name, labels: labels, value: value)
    }

    static func parseValue(_ text: String) -> Double? {
        switch text {
        case "+Inf", "Inf": return .infinity
        case "-Inf": return -.infinity
        case "NaN": return .nan
        default: return Double(text)
        }
    }

    static func unescapeHelp(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

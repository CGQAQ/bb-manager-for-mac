import Foundation

/// Turns a Buildbarn Compose project that was set up by hand into BB Manager settings.
///
/// Settings come from the running system rather than from its configuration files,
/// which can be arbitrary Jsonnet: ports and images from Docker, storage sizes from
/// the data files on disk, and instance name, platform and concurrency from the
/// scheduler's metrics.
public struct TakeoverPlan: Sendable {
    public var projectName: String
    public var workingDirectory: String
    public var composeFiles: [String]
    public var images: ImageSet
    public var main: MainNodeSettings
    /// Nil when the project runs no worker.
    public var worker: WorkerSettings?
    /// Human-readable findings, shown before taking over.
    public var findings: [String]
    /// Things that could not be detected and fell back to defaults.
    public var warnings: [String]
    /// Bytes of cached data in the old project that will not be carried over.
    public var cacheBytes: Int64
}

public enum TakeoverSurvey {
    // MARK: Remote script

    /// Collects containers, data file sizes and scheduler metrics for one project.
    public static func script(project: String) -> String {
        let filter = Shell.quote("label=com.docker.compose.project=" + project)
        return """
        bbm_fetch_url() {
          if command -v curl >/dev/null 2>&1; then curl -fsS --connect-timeout 1 --max-time 5 "$1" 2>/dev/null
          elif command -v wget >/dev/null 2>&1; then wget -qO- -T 5 "$1" 2>/dev/null
          fi
        }
        tmp=$(mktemp 2>/dev/null || echo "/tmp/bbm-survey.$$")
        ids=$(docker ps -aq --filter \(filter))
        echo '@@containers'
        for c in $ids; do
          docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.HostConfig.Privileged}}|{{.State.Running}}|{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{$p}}={{.HostPort}};{{end}}{{end}}|{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c"
        done
        echo '@@files'
        for c in $ids; do
          svc=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$c")
          docker inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\\n"}}{{end}}' "$c" | while IFS='|' read -r src dst; do
            case "$dst" in
              /storage-*|/worker)
                for f in blocks key_location_map cs/blocks filepool; do
                  if [ -f "$src/$f" ]; then echo "$svc|$dst|$f|$(stat -c %s "$src/$f" 2>/dev/null || wc -c < "$src/$f")"; fi
                done
                if [ -d "$src/persistent_state" ]; then echo "$svc|$dst|persistent_state|0"; fi
                ;;
            esac
          done
        done
        echo '@@usage'
        for c in $ids; do
          docker inspect -f '{{range .Mounts}}{{.Source}}{{"\\n"}}{{end}}' "$c"
        done | sort -u | while read -r src; do
          case "$src" in */volumes/*) du -sk "$src" 2>/dev/null ;; esac
        done
        echo '@@scheduler'
        for c in $ids; do
          info=$(docker inspect -f '{{.Config.Image}}|{{.State.Running}}|{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c")
          case "$info" in *buildbarn/bb-scheduler*'|true|'*) ;; *) continue ;; esac
          ip=$(printf '%s' "${info##*|}" | awk '{print $1}')
          [ -n "$ip" ] || continue
          for port in 80 9980; do
            if bbm_fetch_url "http://$ip:$port/metrics" > "$tmp" && [ -s "$tmp" ]; then
              grep -E '^buildbarn_builder_in_memory_build_queue_workers_(created|removed)_total' "$tmp"
              break
            fi
          done
        done
        rm -f "$tmp"
        """
    }

    // MARK: Parsing

    struct Container {
        var service: String
        var image: String
        var privileged: Bool
        var running: Bool
        /// Container port ("8980/tcp") to host port.
        var ports: [String: Int]

        func hostPort(for containerPort: Int) -> Int? {
            ports["\(containerPort)/tcp"]
        }
    }

    public static func plan(
        output: String,
        project: ComposeProject,
        machine: Machine,
        existing cluster: ClusterConfiguration
    ) -> TakeoverPlan {
        let poll = PollOutput(output)
        var findings: [String] = []
        var warnings: [String] = []

        let containers: [Container] = (poll["containers"] ?? "").split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, !f[0].isEmpty else { return nil }
            var ports: [String: Int] = [:]
            for binding in f[4].split(separator: ";") {
                let parts = binding.split(separator: "=")
                if parts.count == 2, let port = Int(parts[1]) { ports[String(parts[0])] = port }
            }
            return Container(service: f[0], image: f[1], privileged: f[2] == "true", running: f[3] == "true", ports: ports)
        }
        func withImage(_ fragment: String) -> [Container] {
            containers.filter { $0.image.contains(fragment) }
        }

        // Data files: service -> mount -> file -> bytes.
        var files: [String: [String: [String: Int64]]] = [:]
        for line in (poll["files"] ?? "").split(separator: "\n") {
            let f = line.split(separator: "|").map(String.init)
            guard f.count == 4, let bytes = Int64(f[3]) else { continue }
            files[f[0], default: [:]][f[1], default: [:]][f[2]] = bytes
        }
        let cacheKB = (poll["usage"] ?? "").split(separator: "\n").compactMap { Int64($0.split(whereSeparator: \.isWhitespace).first ?? "") }.reduce(0, +)

        // Images: keep exactly what runs today.
        var images = cluster.images
        let storageContainers = withImage("buildbarn/bb-storage")
        if let image = storageContainers.first?.image { images.storage = image }
        if let image = withImage("buildbarn/bb-scheduler").first?.image { images.scheduler = image }
        if let image = withImage("buildbarn/bb-worker").first?.image { images.worker = image }
        if let image = withImage("buildbarn/bb-runner-installer").first?.image { images.runnerInstaller = image }
        if let image = withImage("buildbarn/bb-portal").first?.image { images.portal = image }

        // Main node.
        var main = cluster.main?.machineID == machine.id ? cluster.main! : MainNodeSettings(machineID: machine.id, advertisedAddress: "")
        main.machineID = machine.id
        if main.advertisedAddress.isEmpty {
            let host = machine.host
            main.advertisedAddress = (host.contains(".") || host.contains(":")) ? host : (machine.facts?.primaryAddress ?? host)
        }
        main.fileOverrides = [:]
        main.deployedAt = nil
        main.deployedFingerprint = nil

        let frontend = storageContainers.first { $0.service.contains("frontend") }
            ?? storageContainers.first { !$0.ports.isEmpty }
        let storageServers = storageContainers.filter { $0.service != frontend?.service }
        if let port = frontend?.hostPort(for: 8980) ?? frontend?.ports.values.min() {
            main.frontendPort = port
            findings.append("Frontend on port \(port)")
        } else {
            warnings.append("The frontend publishes no port; using \(main.frontendPort).")
        }
        if let port = withImage("buildbarn/bb-scheduler").first?.hostPort(for: 8983) {
            main.schedulerWorkerPort = port
            findings.append("Scheduler accepts workers on port \(port)")
        }
        main.storage.shards = max(1, storageServers.count)

        let storageFiles = storageServers.first.flatMap { files[$0.service] } ?? [:]
        func blocks(_ mount: String) -> Int64? { storageFiles[mount]?["blocks"] }
        if let cas = blocks("/storage-cs") {
            main.storage.casSizeGiB = rounded(Double(cas) / gib)
            findings.append("Content addressable storage: \(Format.bytes(cas)) per shard")
        } else {
            warnings.append("Could not read the storage size; using \(Int(main.storage.casSizeGiB)) GiB.")
        }
        if let ac = blocks("/storage-ac") { main.storage.actionCacheSizeMiB = max(16, (Double(ac) / mib).rounded()) }
        if let cms = blocks("/storage-cms") { main.storage.chunkMappingSizeMiB = max(16, (Double(cms) / mib).rounded()) }
        if let fsac = blocks("/storage-fsac") { main.storage.fileSystemAccessCacheSizeMiB = max(16, (Double(fsac) / mib).rounded()) }
        main.storage.persistent = storageFiles["/storage-cs"]?["persistent_state"] != nil || storageFiles.isEmpty

        if let portal = withImage("buildbarn/bb-portal").first {
            main.portal.enabled = true
            if let http = portal.hostPort(for: 8081) { main.portal.httpPort = http }
            if let bes = portal.hostPort(for: 8082) { main.portal.besPort = bes }
            findings.append("bb-portal on port \(main.portal.httpPort)")
        } else {
            main.portal.enabled = false
        }

        // Worker.
        var worker: WorkerSettings?
        if let workerContainer = withImage("buildbarn/bb-worker").first {
            var settings = cluster.workerDefaults
            settings.kind = workerContainer.privileged ? .fuse : .hardlinking
            if let runner = containers.first(where: { $0.service.contains("runner") && !$0.image.contains("buildbarn/") }) {
                settings.runnerImage = runner.image
            }

            let platforms = schedulerPlatforms(poll["scheduler"] ?? "")
            if let platform = platforms.max(by: { $0.slots < $1.slots }) {
                settings.instanceNamePrefix = platform.instanceNamePrefix
                settings.platformProperties = platform.properties.map { PlatformProperty(name: $0.name, value: $0.value) }
                // Keep the platform exactly as before so Bazel's exec properties still match.
                settings.advertiseContainerImage = false
                let props = platform.properties.map { "\($0.name)=\($0.value)" }.joined(separator: ", ")
                findings.append("Instance name \(platform.instanceNamePrefix.isEmpty ? "(default)" : "“\(platform.instanceNamePrefix)”"), platform \(props.isEmpty ? "(empty)" : props)")
            } else {
                warnings.append("The scheduler's metrics were not readable, so the instance name and platform could not be detected. Check them in the worker's settings after taking over.")
            }
            let schedulerSlots = platforms.max(by: { $0.slots < $1.slots })?.slots ?? 0

            // The scheduler counts slots of every worker on the platform, including workers
            // on other machines. A FUSE worker's scratch file is sized concurrency × per-action
            // size (1 GiB by convention), which identifies this worker's own concurrency.
            let workerFiles = files[workerContainer.service]?["/worker"] ?? [:]
            var concurrency = schedulerSlots
            if settings.kind == .fuse {
                if let cache = workerFiles["cs/blocks"] {
                    settings.localCacheSizeGiB = rounded(Double(cache) / gib)
                }
                if let pool = workerFiles["filepool"], pool > 0 {
                    let wholeGiB = pool % Int64(gib) == 0 ? Int(pool / Int64(gib)) : 0
                    if wholeGiB > 0 && (schedulerSlots == 0 || wholeGiB <= schedulerSlots) {
                        concurrency = wholeGiB
                        settings.filePoolPerActionGiB = 1
                    } else if schedulerSlots > 0 {
                        settings.filePoolPerActionGiB = max(0.125, rounded(Double(pool) / gib / Double(schedulerSlots)))
                    }
                }
            }
            if concurrency > 0 {
                settings.concurrency = concurrency
                findings.append("\(concurrency) concurrent actions")
            } else {
                warnings.append("Could not detect the worker's concurrency; using \(settings.concurrency).")
            }
            if schedulerSlots > concurrency, concurrency > 0 {
                findings.append("\(schedulerSlots - concurrency) more executor slots come from workers on other machines. They keep working because the scheduler and frontend stay on the same ports.")
            }
            findings.append("\(settings.kind == .fuse ? "FUSE" : "Hardlinking") worker with a \(Format.bytes(Int64(settings.localCacheSizeGiB * gib))) local cache")
            worker = settings
        }

        return TakeoverPlan(
            projectName: project.name,
            workingDirectory: project.workingDirectory,
            composeFiles: project.composeFiles,
            images: images,
            main: main,
            worker: worker,
            findings: findings,
            warnings: warnings,
            cacheBytes: cacheKB * 1024
        )
    }

    struct Platform {
        var instanceNamePrefix: String
        var properties: [(name: String, value: String)]
        var slots: Int
    }

    /// Worker platforms registered with the scheduler and how many slots each has.
    static func schedulerPlatforms(_ text: String) -> [Platform] {
        let snapshot = PrometheusParser.parse(text)
        let prefix = "buildbarn_builder_in_memory_build_queue_"
        var created: [String: (prefix: String, platform: String, count: Double)] = [:]
        for sample in snapshot.samples(prefix + "workers_created_total") {
            let key = (sample.labels["instance_name_prefix"] ?? "") + "\u{0}" + (sample.labels["platform"] ?? "")
            created[key, default: (sample.labels["instance_name_prefix"] ?? "", sample.labels["platform"] ?? "", 0)].count += sample.value
        }
        var removed: [String: Double] = [:]
        for sample in snapshot.samples(prefix + "workers_removed_total") {
            let key = (sample.labels["instance_name_prefix"] ?? "") + "\u{0}" + (sample.labels["platform"] ?? "")
            removed[key, default: 0] += sample.value
        }
        return created.map { key, value in
            Platform(
                instanceNamePrefix: value.prefix,
                properties: parsePlatform(value.platform),
                slots: max(0, Int(value.count - (removed[key] ?? 0)))
            )
        }
    }

    /// Parses the scheduler's `{"properties":[{"name":"pool","value":"default"}]}` label.
    static func parsePlatform(_ json: String) -> [(name: String, value: String)] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = object["properties"] as? [[String: Any]] else { return [] }
        return properties.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return (name: name, value: item["value"] as? String ?? "")
        }
    }

    static let gib = 1024.0 * 1024 * 1024
    static let mib = 1024.0 * 1024

    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: Cutover scripts

    /// Compose arguments that address the project the way it was started.
    static func projectPrelude(_ plan: TakeoverPlan) -> String {
        var script = """
        \(Shell.detectCompose)
        if [ -z "$DC" ]; then echo "error: Docker Compose is not installed."; exit 127; fi
        cd \(Shell.quote(plan.workingDirectory)) 2>/dev/null || cd /
        set -- -p \(Shell.quote(plan.projectName))

        """
        for file in plan.composeFiles {
            script += "if [ -f \(Shell.quote(file)) ]; then set -- \"$@\" -f \(Shell.quote(file)); fi\n"
        }
        return script
    }

    /// Stops and removes the old project's containers. Its files and data stay on disk.
    public static func stopScript(_ plan: TakeoverPlan) -> String {
        """
        set -e
        exec 2>&1
        \(projectPrelude(plan))
        echo "==> Stopping \(plan.projectName). Its files and data stay in \(plan.workingDirectory)."
        $DC "$@" down

        """
    }

    /// Removes BB Manager's new containers and starts the old project again.
    public static func rollbackScript(_ plan: TakeoverPlan, newDirectories: [String]) -> String {
        var script = "exec 2>&1\n\(Shell.detectCompose)\n"
        for directory in newDirectories {
            script += """
            if [ -f \(Shell.quote(directory))/docker-compose.yml ]; then
              echo "==> Removing new containers in \(directory)"
              (cd \(Shell.quote(directory)) && $DC down --remove-orphans) || true
            fi

            """
        }
        script += """
        \(projectPrelude(plan))
        echo "==> Starting \(plan.projectName) again"
        $DC "$@" up -d

        """
        return script
    }
}

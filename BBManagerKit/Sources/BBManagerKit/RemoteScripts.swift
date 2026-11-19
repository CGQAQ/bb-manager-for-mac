import Foundation

/// POSIX shell scripts executed on remote machines.
public enum RemoteScripts {
    static let requireCompose = """
    \(Shell.detectCompose)
    if [ -z "$DC" ]; then echo "error: Docker Compose is not installed on this machine."; exit 127; fi
    if ! docker info >/dev/null 2>&1; then echo "error: cannot reach the Docker daemon. Is Docker running, and may this user use it?"; exit 1; fi
    """

    // MARK: Preflight

    /// Collects machine facts without elevated privileges. Prints `key=value` lines.
    public static func preflight(installDirectory: String) -> String {
        """
        echo "kernel_name=$(uname -s)"
        if [ "$(uname -s)" = Darwin ]; then
          echo "os=macOS $(sw_vers -productVersion 2>/dev/null)"
          echo "mem_kb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))"
          echo "ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)"
        else
          echo "os=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -s)"
          echo "mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
          echo "ip=$(hostname -I 2>/dev/null | awk '{print $1}')"
        fi
        echo "kernel=$(uname -r)"
        echo "arch=$(uname -m)"
        echo "cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
        echo "uid=$(id -u)"
        if [ -e /dev/fuse ]; then echo fuse=1; else echo fuse=0; fi
        if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then echo http=1; else echo http=0; fi
        if [ "$(id -u)" = 0 ] || sudo -n true >/dev/null 2>&1; then echo sudo_nopasswd=1; else echo sudo_nopasswd=0; fi
        if docker info >/dev/null 2>&1; then echo docker_user=1; else echo docker_user=0; fi
        echo "home=$HOME"
        d=\(Shell.quote(installDirectory))
        while [ ! -d "$d" ]; do d=$(dirname "$d"); done
        if [ -w "$d" ]; then echo install_writable=1; else echo install_writable=0; fi
        df -Pk "$d" 2>/dev/null | awk 'NR==2 {print "disk_total_kb="$2; print "disk_avail_kb="$4}'
        """
    }

    /// Checks Docker with the machine's privilege mode. Prints `key=value` lines.
    public static let dockerCheck = """
    echo "docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    echo "compose=$(docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null)"
    """

    public static func parseKeyValues(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value
        }
        return result
    }

    public static func facts(preflight: String, docker: String?) -> MachineFacts {
        let kv = parseKeyValues(preflight).merging(parseKeyValues(docker ?? "")) { $1 }
        var facts = MachineFacts()
        facts.osName = kv["os"].flatMap { $0.isEmpty ? nil : $0 }
        facts.kernel = kv["kernel"]
        facts.architecture = kv["arch"]
        facts.cpuCount = kv["cpus"].flatMap { Int($0) }
        facts.memoryBytes = kv["mem_kb"].flatMap { Int64($0) }.map { $0 * 1024 }
        facts.primaryAddress = kv["ip"].flatMap { $0.isEmpty ? nil : $0 }
        facts.hasFuse = kv["fuse"].map { $0 == "1" }
        facts.hasHTTPClient = kv["http"].map { $0 == "1" }
        facts.isRoot = kv["uid"].map { $0 == "0" }
        facts.passwordlessSudo = kv["sudo_nopasswd"].map { $0 == "1" }
        facts.kernelName = kv["kernel_name"].flatMap { $0.isEmpty ? nil : $0 }
        facts.dockerWithoutSudo = kv["docker_user"].map { $0 == "1" }
        facts.installDirectoryWritable = kv["install_writable"].map { $0 == "1" }
        facts.homeDirectory = kv["home"].flatMap { $0.isEmpty ? nil : $0 }
        facts.diskTotalBytes = kv["disk_total_kb"].flatMap { Int64($0) }.map { $0 * 1024 }
        facts.diskAvailableBytes = kv["disk_avail_kb"].flatMap { Int64($0) }.map { $0 * 1024 }
        if docker != nil {
            facts.dockerVersion = kv["docker"] ?? ""
            facts.composeVersion = kv["compose"] ?? ""
        }
        return facts
    }

    /// Installs Docker Engine using Docker's official convenience script.
    public static let installDocker = """
    set -e
    exec 2>&1
    echo "==> Downloading https://get.docker.com"
    if command -v curl >/dev/null 2>&1; then curl -fsSL https://get.docker.com -o /tmp/bbm-get-docker.sh
    elif command -v wget >/dev/null 2>&1; then wget -qO /tmp/bbm-get-docker.sh https://get.docker.com
    else echo "error: neither curl nor wget is installed."; exit 1; fi
    echo "==> Running Docker's installer"
    sh /tmp/bbm-get-docker.sh
    rm -f /tmp/bbm-get-docker.sh
    systemctl enable --now docker 2>/dev/null || true
    echo "==> Installed"
    docker version
    """

    // MARK: Deployment

    public static func deploy(_ plan: NodePlan, pullImages: Bool) -> String {
        var script = """
        set -e
        exec 2>&1
        \(requireCompose)
        DIR=\(Shell.quote(plan.directory))
        echo "==> Writing configuration to $DIR"
        mkdir -p "$DIR/config"
        cd "$DIR"

        """
        for file in plan.files {
            let encoded = Data(file.content.utf8).base64EncodedString()
            let path = Shell.quote(file.path)
            let tmp = Shell.quote(file.path + ".bbm-tmp")
            let parent = (file.path as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                script += "mkdir -p \(Shell.quote(parent))\n"
            }
            script += "printf '%s' '\(encoded)' | base64 -d > \(tmp) && mv \(tmp) \(path)\n"
        }
        if plan.stopBeforeDeploy {
            script += """
            echo "==> Stopping running services"
            $DC down --remove-orphans || true

            """
        }
        script += """
        echo "==> Preparing data directories"
        \(plan.prepareScript)

        """
        if pullImages {
            script += """
            echo "==> Pulling images (the first run can take a few minutes)"
            $DC pull

            """
        }
        script += """
        echo "==> Starting services"
        $DC up -d --remove-orphans
        echo "==> Status"
        $DC ps
        echo "==> Done"
        """
        return script
    }

    public enum ComposeAction: String, Sendable {
        case start, stop, restart, pull

        public var title: String {
            switch self {
            case .start: "Start"
            case .stop: "Stop"
            case .restart: "Restart"
            case .pull: "Pull Images"
            }
        }
    }

    public static func compose(_ action: ComposeAction, directory: String, service: String? = nil) -> String {
        let target = service.map { " " + Shell.quote($0) } ?? ""
        let command: String
        switch action {
        case .start: command = service == nil ? "$DC up -d --remove-orphans" : "$DC start\(target)"
        case .stop: command = "$DC stop\(target)"
        case .restart: command = "$DC restart\(target)"
        case .pull: command = "$DC pull\(target)"
        }
        return """
        set -e
        exec 2>&1
        \(requireCompose)
        cd \(Shell.quote(directory))
        \(command)
        $DC ps
        """
    }

    public static func logs(directory: String, service: String?, tail: Int, follow: Bool) -> String {
        let target = service.map { " " + Shell.quote($0) } ?? ""
        return """
        exec 2>&1
        \(requireCompose)
        cd \(Shell.quote(directory)) || exit 1
        exec $DC logs --no-color --timestamps --tail \(max(1, tail))\(follow ? " --follow" : "")\(target)
        """
    }

    public static func uninstall(directory: String, removeData: Bool) -> String {
        var script = """
        exec 2>&1
        \(Shell.detectCompose)
        DIR=\(Shell.quote(directory))
        if [ -d "$DIR" ]; then
          cd "$DIR"
          if [ -n "$DC" ] && [ -f docker-compose.yml ]; then
            echo "==> Stopping and removing containers"
            $DC down --remove-orphans || true
          fi
          umount volumes/worker/build 2>/dev/null || umount -l volumes/worker/build 2>/dev/null || true

        """
        if removeData {
            script += """
              cd /
              echo "==> Deleting $DIR"
              rm -rf "$DIR"

            """
        } else {
            script += "  echo \"==> Containers removed; data kept in $DIR\"\n"
        }
        script += """
        else
          echo "Nothing installed in $DIR"
        fi
        echo "==> Done"
        """
        return script
    }

    // MARK: Monitoring

    public struct PollNode: Sendable {
        public var key: String
        public var directory: String
        public var diagnostics: [DiagnosticsEndpoint]
        public var runtime: NodeRuntime

        public init(key: String, directory: String, diagnostics: [DiagnosticsEndpoint], runtime: NodeRuntime = .compose) {
            self.key = key
            self.directory = directory
            self.diagnostics = diagnostics
            self.runtime = runtime
        }
    }

    // MARK: Dispatch by runtime

    /// Deploys a node with Docker Compose or launchd, as its plan requires.
    public static func install(_ plan: NodePlan, pullImages: Bool) -> String {
        plan.runtime == .launchd ? LaunchdScripts.deploy(plan) : deploy(plan, pullImages: pullImages)
    }

    public static func control(_ action: ComposeAction, plan: NodePlan, service: String? = nil) -> String {
        plan.runtime == .launchd
            ? LaunchdScripts.action(action, directory: plan.directory, service: service)
            : compose(action, directory: plan.directory, service: service)
    }

    public static func logs(plan: NodePlan, service: String?, tail: Int, follow: Bool) -> String {
        plan.runtime == .launchd
            ? LaunchdScripts.logs(directory: plan.directory, service: service, tail: tail, follow: follow)
            : logs(directory: plan.directory, service: service, tail: tail, follow: follow)
    }

    public static func remove(_ plan: NodePlan, removeData: Bool) -> String {
        plan.runtime == .launchd
            ? LaunchdScripts.uninstall(directory: plan.directory, removeData: removeData)
            : uninstall(directory: plan.directory, removeData: removeData)
    }

    /// Host statistics for Linux (/proc) and macOS (sysctl, vm_stat, ps).
    static let hostStats = """
    if [ "$(uname -s)" = Darwin ]; then
      echo '@@loadavg'; sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'
      echo '@@cpupercent'; ps -A -o %cpu= 2>/dev/null | awk -v n="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)" '{s+=$1} END {if (n > 0) printf "%.1f\\n", s/n}'
      echo '@@meminfo'; vm_stat 2>/dev/null | awk -v total="$(sysctl -n hw.memsize 2>/dev/null || echo 0)" '/page size of/ {ps=$8} /^Pages free/ {f=$3} /^Pages inactive/ {i=$3} /^Pages speculative/ {s=$3} END {gsub(/\\./,"",f); gsub(/\\./,"",i); gsub(/\\./,"",s); printf "MemTotal: %d kB\\nMemAvailable: %d kB\\n", total/1024, (f+i+s)*ps/1024}'
    else
      echo '@@loadavg'; cat /proc/loadavg 2>/dev/null
      echo '@@stat'; head -n 1 /proc/stat 2>/dev/null
      echo '@@meminfo'; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null
    fi
    """

    static let fetchFunction = """
    bbm_fetch() {
      if command -v curl >/dev/null 2>&1; then curl -fsS --max-time 4 "http://127.0.0.1:$1/metrics" 2>/dev/null
      elif command -v wget >/dev/null 2>&1; then wget -qO- -T 4 "http://127.0.0.1:$1/metrics" 2>/dev/null
      fi
    }
    """

    /// One round-trip that gathers host load, container state and Prometheus metrics.
    ///
    /// Output is split into sections that start with `@@<name>` lines; see `PollOutput`.
    public static func poll(installDirectory: String, nodes: [PollNode], includeMetrics: Bool) -> String {
        var script = """
        \(Shell.detectCompose)
        \(fetchFunction)
        \(hostStats)
        echo '@@disk'
        d=\(Shell.quote(installDirectory))
        while [ ! -d "$d" ]; do d=$(dirname "$d"); done
        df -Pk "$d" 2>/dev/null | awk 'NR==2'
        echo '@@dockerstats'; docker stats --no-stream --format '{{json .}}' 2>/dev/null
        echo '@@projects'
        docker ps -a --filter label=com.docker.compose.project --format \(Shell.quote(ComposeProject.psFormat)) 2>/dev/null

        """
        for node in nodes {
            let dir = Shell.quote(node.directory)
            if node.runtime == .launchd {
                script += """
                echo '@@compose \(node.key)'
                (
                \(LaunchdScripts.statusSection(directory: node.directory))
                )

                """
            } else {
                script += """
                echo '@@compose \(node.key)'
                if [ -n "$DC" ] && [ -f \(dir)/docker-compose.yml ]; then (cd \(dir) && $DC ps -a --format json 2>/dev/null); fi

                """
            }
            if includeMetrics {
                for endpoint in node.diagnostics {
                    script += "echo '@@metrics \(node.key) \(endpoint.service)'; bbm_fetch \(endpoint.port) | grep -v '_bucket{'\n"
                }
            }
        }
        return script
    }

    /// Fetches the complete metrics page of one endpoint, histogram buckets included.
    public static func fetchMetrics(port: Int) -> String {
        """
        \(fetchFunction)
        bbm_fetch \(port)
        """
    }
}

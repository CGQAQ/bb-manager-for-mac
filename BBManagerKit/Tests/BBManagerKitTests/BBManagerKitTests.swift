import Foundation
import Testing
@testable import BBManagerKit

@Suite struct ShellTests {
    @Test func quotesSingleQuotes() {
        #expect(Shell.quote("it's") == #"'it'\''s'"#)
        #expect(Shell.quote("plain") == "'plain'")
    }

    @Test func wrapsWithSudo() {
        #expect(Shell.remoteCommand(script: "id", privilege: .sudo).hasPrefix("sudo -n sh -c '"))
        #expect(Shell.remoteCommand(script: "id", privilege: .sudoWithPassword).hasPrefix("sudo -k -S -p '' sh -c '"))
        #expect(Shell.remoteCommand(script: "id", privilege: nil).hasPrefix("sh -c '"))
    }

    @Test func remoteCommandRoundTripsThroughShell() throws {
        let script = #"echo "a'b" && printf '%s\n' "$HOME" | wc -c"#
        let command = Shell.remoteCommand(script: script, privilege: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.hasPrefix("a'b\n"))
        #expect(process.terminationStatus == 0)
    }
}

@Suite struct SSHArgumentTests {
    @Test func buildsArguments() {
        var machine = Machine(name: "m", host: "build1.example.com", port: 2222, user: "ci", auth: .identityFile, identityFile: "~/.ssh/id_ed25519")
        let args = SSHClient().arguments(for: machine, remoteCommand: "true", options: SSHOptions())
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("-p"))
        #expect(args.contains("2222"))
        #expect(args.suffix(3) == ["--", "ci@build1.example.com", "true"])
        #expect(args.contains { $0.hasSuffix("/.ssh/id_ed25519") && !$0.hasPrefix("~") })

        machine.auth = .password
        let passwordArgs = SSHClient().arguments(for: machine, remoteCommand: nil, options: SSHOptions())
        #expect(!passwordArgs.contains("BatchMode=yes"))
        #expect(passwordArgs.last == "ci@build1.example.com")
    }

    @Test func validatesMachines() {
        #expect(Machine(host: "-oProxyCommand=x").validationErrors.isEmpty == false)
        #expect(Machine(host: "ok", installDirectory: "/").validationErrors.isEmpty == false)
        #expect(Machine(host: "ok").validationErrors.isEmpty)
    }

    @Test func mapsSudoErrors() {
        #expect(SSHClient.sudoError(in: "sudo: a password is required", privilege: .sudo) == .sudoPasswordRequired)
        #expect(SSHClient.sudoError(in: "sudo: a password is required", privilege: PrivilegeMode.none) == nil)
    }
}

@Suite struct PrometheusTests {
    static let sample = """
    # HELP buildbarn_builder_in_memory_build_queue_tasks_scheduled_total Number of times tasks were scheduled.
    # TYPE buildbarn_builder_in_memory_build_queue_tasks_scheduled_total counter
    buildbarn_builder_in_memory_build_queue_tasks_scheduled_total{assignment="Queued",do_not_cache="false",instance_name_prefix="",platform="{\\"properties\\":[]}",size_class="0"} 40
    buildbarn_builder_in_memory_build_queue_tasks_scheduled_total{assignment="Queued",do_not_cache="true",instance_name_prefix="",platform="x",size_class="0"} 2
    # HELP buildbarn_builder_in_memory_build_queue_tasks_queued_duration_seconds Time in seconds that tasks were queued before executing.
    # TYPE buildbarn_builder_in_memory_build_queue_tasks_queued_duration_seconds histogram
    buildbarn_builder_in_memory_build_queue_tasks_queued_duration_seconds_bucket{instance_name_prefix="",platform="x",size_class="0",le="0.1"} 30
    buildbarn_builder_in_memory_build_queue_tasks_queued_duration_seconds_bucket{instance_name_prefix="",platform="x",size_class="0",le="+Inf"} 40
    buildbarn_builder_in_memory_build_queue_tasks_queued_duration_seconds_sum{instance_name_prefix="",platform="x",size_class="0"} 20
    buildbarn_builder_in_memory_build_queue_tasks_queued_duration_seconds_count{instance_name_prefix="",platform="x",size_class="0"} 40
    # TYPE buildbarn_builder_in_memory_build_queue_tasks_executing_duration_seconds histogram
    buildbarn_builder_in_memory_build_queue_tasks_executing_duration_seconds_sum{grpc_code="OK",instance_name_prefix="",platform="x",result="Success",size_class="0"} 100
    buildbarn_builder_in_memory_build_queue_tasks_executing_duration_seconds_count{grpc_code="OK",instance_name_prefix="",platform="x",result="Success",size_class="0"} 35
    buildbarn_builder_in_memory_build_queue_tasks_executing_duration_seconds_count{grpc_code="OK",instance_name_prefix="",platform="x",result="Failure",size_class="0"} 3
    # TYPE buildbarn_builder_in_memory_build_queue_workers_created_total counter
    buildbarn_builder_in_memory_build_queue_workers_created_total{instance_name_prefix="",platform="x",size_class="0"} 10
    # TYPE buildbarn_builder_in_memory_build_queue_workers_removed_total counter
    buildbarn_builder_in_memory_build_queue_workers_removed_total{instance_name_prefix="",platform="x",size_class="0",state="Idle"} 2
    # HELP go_goroutines Number of goroutines that currently exist.
    # TYPE go_goroutines gauge
    go_goroutines 123
    process_start_time_seconds 1.7e+09
    weird_value NaN
    """

    @Test func parsesFamilies() {
        let snapshot = PrometheusParser.parse(Self.sample)
        let scheduled = snapshot.families["buildbarn_builder_in_memory_build_queue_tasks_scheduled_total"]
        #expect(scheduled?.type == .counter)
        #expect(scheduled?.samples.count == 2)
        #expect(scheduled?.samples.first?.labels["platform"] == #"{"properties":[]}"#)
        let queued = snapshot.families["buildbarn_builder_in_memory_build_queue_tasks_queued_duration_seconds"]
        #expect(queued?.type == .histogram)
        #expect(queued?.samples.count == 4)
        #expect(snapshot.sum("go_goroutines") == 123)
        #expect(snapshot.sum("process_start_time_seconds") == 1.7e9)
        #expect(snapshot.families["weird_value"]?.samples.first?.value.isNaN == true)
    }

    @Test func summarisesScheduler() throws {
        let summary = try #require(SchedulerSummary(PrometheusParser.parse(Self.sample)))
        #expect(summary.executorSlots == 8)
        #expect(summary.tasksScheduled == 42)
        #expect(summary.queued == 2)
        #expect(summary.executing == 2)
        #expect(summary.averageQueueSeconds == 0.5)
        #expect(summary.resultCounts["Failure"] == 3)
    }

    @Test func summarisesFrontend() throws {
        let text = """
        buildbarn_blobstore_blob_access_operations_duration_seconds_count{backend_type="completeness_checking",grpc_code="OK",operation="Get",storage_type="AC"} 30
        buildbarn_blobstore_blob_access_operations_duration_seconds_count{backend_type="completeness_checking",grpc_code="NotFound",operation="Get",storage_type="AC"} 10
        buildbarn_blobstore_blob_access_operations_duration_seconds_count{backend_type="grpc",grpc_code="OK",operation="Get",storage_type="AC"} 30
        buildbarn_blobstore_blob_access_operations_duration_seconds_count{backend_type="grpc",grpc_code="NotFound",operation="Get",storage_type="AC"} 5
        grpc_server_handled_total{grpc_code="OK",grpc_method="Execute",grpc_service="build.bazel.remote.execution.v2.Execution",grpc_type="server_stream"} 7
        """
        let summary = try #require(FrontendSummary(PrometheusParser.parse(text)))
        #expect(summary.actionCacheHitRate == 0.75)
        #expect(summary.grpcCalls["Execution.Execute"] == 7)
    }

    @Test func countersHandleResets() {
        #expect(counterRate(previous: 10, current: 20, seconds: 5) == 2)
        #expect(counterRate(previous: 100, current: 20, seconds: 10) == 2)
        #expect(counterRate(previous: nil, current: 20, seconds: 10) == nil)
    }
}

@Suite struct MonitoringTests {
    @Test func parsesPollOutput() throws {
        let text = """
        @@loadavg
        0.50 0.40 0.30 1/200 1234
        @@stat
        cpu  100 0 100 800 0 0 0 0 0 0
        @@meminfo
        MemTotal:        8000000 kB
        MemAvailable:    6000000 kB
        @@disk
        /dev/sda1 100000 40000 60000 40% /
        @@dockerstats
        {"BlockIO":"0B / 0B","CPUPerc":"1.50%","Container":"abc","MemPerc":"2.00%","MemUsage":"30MiB / 7.7GiB","Name":"buildbarn-main-frontend-1"}
        @@compose main
        {"Name":"buildbarn-main-frontend-1","Service":"frontend","State":"running","Status":"Up 2 minutes","Image":"ghcr.io/buildbarn/bb-storage:x","Publishers":[{"URL":"0.0.0.0","TargetPort":8980,"PublishedPort":8980,"Protocol":"tcp"}]}
        {"Name":"buildbarn-main-scheduler-1","Service":"scheduler","State":"exited","Status":"Exited (1)","Image":"ghcr.io/buildbarn/bb-scheduler:x","ExitCode":1}
        @@metrics main frontend
        go_goroutines 12
        """
        let output = PollOutput(text)
        let previous = CPUCounters(total: 500, idle: 400)
        let host = output.host(previousCPU: previous)
        #expect(host.load1 == 0.5)
        #expect(host.memoryUsage == 0.25)
        #expect(host.diskUsage == 0.4)
        #expect(abs((host.cpuUsage ?? 0) - 0.2) < 0.0001)
        #expect(output.dockerStats.first?.cpuPercent == 1.5)
        let containers = try #require(output.containers(nodeKey: "main"))
        #expect(containers.count == 2)
        #expect(containers.first?.publishedPorts == "8980→8980")
        #expect(containers.last?.isRunning == false)
        #expect(output.metrics(nodeKey: "main", service: "frontend")?.sum("go_goroutines") == 12)
    }

    @Test func parsesComposeJSONArray() {
        let containers = ContainerStatus.parse(#"[{"Name":"a","Service":"b","State":"running","Status":"Up","Image":"i"}]"#)
        #expect(containers.count == 1)
    }

    @Test func parsesFacts() {
        let facts = RemoteScripts.facts(
            preflight: "os=Ubuntu 24.04 LTS\ncpus=16\nmem_kb=1024\nuid=1000\nfuse=1\nsudo_nopasswd=1\ndisk_avail_kb=10",
            docker: "docker=27.1.1\ncompose=2.29.0"
        )
        #expect(facts.osName == "Ubuntu 24.04 LTS")
        #expect(facts.cpuCount == 16)
        #expect(facts.memoryBytes == Int64(1024 * 1024))
        #expect(facts.isRoot == false)
        #expect(facts.dockerReady)
        #expect(facts.diskAvailableBytes == 10240)
    }
}

@Suite struct GeneratorTests {
    static func cluster(portal: Bool = true, shards: Int = 2, kind: WorkerKind = .fuse) -> (ClusterConfiguration, [Machine]) {
        let mainMachine = Machine(name: "main", host: "10.0.0.1", user: "root", privilege: .none)
        let workerMachine = Machine(name: "worker 1", host: "10.0.0.2", user: "ubuntu")
        var cluster = ClusterConfiguration()
        var main = MainNodeSettings(machineID: mainMachine.id, advertisedAddress: "10.0.0.1")
        main.storage.shards = shards
        main.portal.enabled = portal
        cluster.main = main
        var settings = WorkerSettings()
        settings.kind = kind
        settings.concurrency = 4
        cluster.workers = [WorkerNode(machineID: workerMachine.id, settings: settings)]
        return (cluster, [mainMachine, workerMachine])
    }

    @Test func mainPlanHasExpectedFiles() throws {
        let (cluster, machines) = Self.cluster()
        let plan = try #require(ConfigGenerator(cluster: cluster, machines: machines).mainPlan())
        #expect(plan.directory == "/opt/buildbarn/main")
        #expect(plan.files.map(\.path).contains("config/portal.jsonnet"))
        #expect(plan.services == ["frontend", "storage-0", "storage-1", "scheduler", "portal", "postgres"])
        let compose = try #require(plan.files.first { $0.path == "docker-compose.yml" }).content
        #expect(compose.contains("\"8992:8981\""))
        #expect(compose.contains("127.0.0.1:9991:9980"))
        let topology = try #require(plan.files.first { $0.path == "config/topology.libsonnet" }).content
        #expect(topology.contains("'storage-1:8981',"))
        let storage = try #require(plan.files.first { $0.path == "config/storage.jsonnet" }).content
        #expect(storage.contains("sizeBytes: 32 * 1024 * 1024 * 1024"))
        #expect(storage.contains("chunkingParameters"))
        #expect(storage.contains("path: '/storage-cs/key_location_map'"))
    }

    @Test func workerPlanUsesAdvertisedAddress() throws {
        let (cluster, machines) = Self.cluster()
        let generator = ConfigGenerator(cluster: cluster, machines: machines)
        let plan = try #require(generator.workerPlan(cluster.workers[0]))
        let topology = try #require(plan.files.first { $0.path == "config/topology.libsonnet" }).content
        #expect(topology.contains("'10.0.0.1:8991',"))
        #expect(topology.contains("'10.0.0.1:8992',"))
        let worker = try #require(plan.files.first { $0.path == "config/worker.jsonnet" }).content
        #expect(worker.contains("scheduler: { address: '10.0.0.1:8983' }"))
        #expect(worker.contains("concurrency: 4,"))
        #expect(worker.contains("node: 'worker 1',"))
        #expect(worker.contains("{ name: 'container-image', value: 'docker://ghcr.io/catthehacker/ubuntu"))
        #expect(worker.contains("sizeBytes: 4 * 1024 * 1024 * 1024"))
        let compose = try #require(plan.files.first { $0.path == "docker-compose.yml" }).content
        #expect(compose.contains("propagation: shared"))
        #expect(compose.contains("privileged: true"))
    }

    @Test func overridesReplaceContentAndChangeFingerprint() throws {
        var (cluster, machines) = Self.cluster()
        let before = try #require(ConfigGenerator(cluster: cluster, machines: machines).mainPlan())
        cluster.main?.fileOverrides["config/scheduler.jsonnet"] = "{}"
        let after = try #require(ConfigGenerator(cluster: cluster, machines: machines).mainPlan())
        #expect(after.files.first { $0.path == "config/scheduler.jsonnet" }?.content == "{}")
        #expect(before.fingerprint != after.fingerprint)
    }

    @Test func escapesStrings() {
        #expect(ConfigGenerator.jsonnetString("it's") == #"'it\'s'"#)
        #expect(ConfigGenerator.yamlString(#"a"b"#) == #""a\"b""#)
        #expect(ConfigGenerator.sizeExpression(3 * 1024 * 1024) == "3 * 1024 * 1024")
        #expect(ConfigGenerator.sizeExpression(1536 * 1024 * 1024) == "1536 * 1024 * 1024")
    }

    @Test func deployScriptEmbedsFiles() throws {
        let (cluster, machines) = Self.cluster()
        let plan = try #require(ConfigGenerator(cluster: cluster, machines: machines).mainPlan())
        let script = RemoteScripts.deploy(plan, pullImages: true)
        #expect(script.contains("base64 -d > 'config/storage.jsonnet.bbm-tmp'"))
        #expect(script.contains("$DC pull"))
        #expect(Shell.remoteCommand(script: script, privilege: .sudo).utf8.count < 120_000)
    }

    @Test func bazelrcMentionsEndpoints() throws {
        let (cluster, machines) = Self.cluster()
        let rc = try #require(ConfigGenerator(cluster: cluster, machines: machines).bazelrc())
        #expect(rc.contains("--remote_executor=grpc://10.0.0.1:8980"))
        #expect(rc.contains("--bes_backend=grpc://10.0.0.1:8082"))
        #expect(rc.contains("--remote_default_exec_properties=OSFamily=linux"))
    }

    /// Writes a demo state file to $BBM_SAMPLE_STATE (launch the app with `-BBMStateFile <path>`).
    @Test func writeSampleStateIfRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["BBM_SAMPLE_STATE"] else { return }
        var (cluster, machines) = Self.cluster(shards: 1)
        cluster.name = "Demo Cluster"
        for index in machines.indices {
            var facts = MachineFacts()
            facts.osName = "Ubuntu 24.04.1 LTS"
            facts.kernel = "6.8.0-48-generic"
            facts.architecture = "x86_64"
            facts.cpuCount = 16
            facts.memoryBytes = 64 * 1024 * 1024 * 1024
            facts.dockerVersion = "27.3.1"
            facts.composeVersion = "2.29.7"
            facts.hasFuse = true
            facts.hasHTTPClient = true
            facts.diskTotalBytes = 1024 * 1024 * 1024 * 1024
            facts.diskAvailableBytes = 700 * 1024 * 1024 * 1024
            machines[index].facts = facts
            machines[index].host = "192.0.2.\(10 + index)"
        }
        cluster.main?.advertisedAddress = "192.0.2.10"
        try StateStore(url: URL(fileURLWithPath: path)).save(PersistedState(machines: machines, cluster: cluster))
    }

    /// Writes rendered configs to $BBM_RENDER_DIR for manual inspection or validation.
    @Test func renderToDirectoryIfRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["BBM_RENDER_DIR"] else { return }
        for kind in WorkerKind.allCases {
            let (cluster, machines) = Self.cluster(shards: 1, kind: kind)
            let generator = ConfigGenerator(cluster: cluster, machines: machines)
            let plans = [("main", generator.mainPlan()!), ("worker-\(kind.rawValue)", generator.workerPlan(cluster.workers[0])!)]
            for (name, plan) in plans {
                for file in plan.files {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(name).appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.content.write(to: url, atomically: true, encoding: .utf8)
                }
                let script = URL(fileURLWithPath: dir).appendingPathComponent(name).appendingPathComponent("prepare.sh")
                try plan.prepareScript.write(to: script, atomically: true, encoding: .utf8)
            }
        }
    }
}

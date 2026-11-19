import AppKit
import BBManagerKit
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    // MARK: Persisted state

    var machines: [Machine] = [] {
        didSet { scheduleSave() }
    }

    var cluster = ClusterConfiguration() {
        didSet { scheduleSave() }
    }

    // MARK: UI state

    var selection: SidebarItem? = .overview
    var sheet: ActiveSheet?
    var operation: OperationSession?
    var alert: AlertItem?
    var busyNodes: Set<NodeRole> = []

    // MARK: Live state

    var connectivity: [UUID: Connectivity] = [:]
    var hostSamples: [UUID: HostSample] = [:]
    var hostHistory: [UUID: [HostPoint]] = [:]
    var containerUsage: [UUID: [ContainerUsage]] = [:]
    /// Buildbarn Compose projects seen on each machine, including ones BB Manager didn't create.
    var discoveredProjects: [UUID: [ComposeProject]] = [:]
    var nodeRuntime: [NodeRole: NodeRuntime] = [:]
    var metrics: [MetricsKey: MetricsSnapshot] = [:]
    var previousMetrics: [MetricsKey: MetricsSnapshot] = [:]
    var clusterHistory: [ClusterPoint] = []
    var lastPoll: Date?
    var isPolling = false
    var loadError: String?

    /// `-BBMStateFile <path>` points the app at another state file (handy for demos and tests).
    @ObservationIgnored private let store = UserDefaults.standard.string(forKey: "BBMStateFile")
        .map { StateStore(url: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) } ?? StateStore()
    @ObservationIgnored let ssh = SSHClient.shared
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightPolls: Set<UUID> = []
    @ObservationIgnored private var inspectedThisSession: Set<UUID> = []
    @ObservationIgnored private var isLoading = false

    init() {
        AppDefaults.register()
        applySSHSettings()
        isLoading = true
        do {
            let state = try store.load()
            machines = state.machines
            cluster = state.cluster
        } catch {
            loadError = "Could not read saved state: \(error.localizedDescription)"
        }
        isLoading = false
        #if DEBUG
        applyDebugSelection()
        #endif
    }

    #if DEBUG
    /// `-BBMInitialSelection main|workers|statistics|configuration|worker|machine` opens a screen at launch.
    private func applyDebugSelection() {
        switch UserDefaults.standard.string(forKey: "BBMInitialSelection") {
        case "main": selection = .mainNode
        case "workers": selection = .workers
        case "statistics": selection = .statistics
        case "configuration": selection = .configuration
        case "worker": selection = cluster.workers.first.map { .worker($0.id) }
        case "machine": selection = machines.first.map { .machine($0.id) }
        default: break
        }
        // `-BBMInitialSheet addMachine|editMachine|addWorker` opens a sheet at launch.
        switch UserDefaults.standard.string(forKey: "BBMInitialSheet") {
        case "addMachine": sheet = .addMachine
        case "editMachine": sheet = machines.first.map { .editMachine($0.id) }
        case "addWorker": sheet = .addWorker(preselectedMachine: nil)
        default: break
        }
    }
    #endif

    // MARK: - Persistence

    private func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try store.save(PersistedState(machines: machines, cluster: cluster))
        } catch {
            alert = AlertItem(title: "Could Not Save", message: error.localizedDescription)
        }
    }

    func applySSHSettings() {
        let defaults = UserDefaults.standard
        var options = SSHOptions()
        options.sshPath = defaults.string(forKey: AppDefaults.sshPath) ?? "/usr/bin/ssh"
        options.connectTimeout = max(2, defaults.integer(forKey: AppDefaults.sshConnectTimeout))
        options.extraOptions = (defaults.string(forKey: AppDefaults.sshExtraOptions) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        options.askpassExecutable = Bundle.main.executablePath
        ssh.options = options
    }

    // MARK: - Lookups

    func machine(_ id: UUID?) -> Machine? {
        guard let id else { return nil }
        return machines.first { $0.id == id }
    }

    var mainMachine: Machine? { machine(cluster.main?.machineID) }

    var generator: ConfigGenerator { ConfigGenerator(cluster: cluster, machines: machines) }

    func plan(_ role: NodeRole) -> NodePlan? { generator.plan(for: role) }

    func machine(for role: NodeRole) -> Machine? {
        switch role {
        case .main: mainMachine
        case .worker(let id): machine(cluster.worker(id: id)?.machineID)
        }
    }

    func title(for role: NodeRole) -> String {
        switch role {
        case .main: "Main Node"
        case .worker: machine(for: role)?.displayName ?? "Worker"
        }
    }

    func roles(on machineID: UUID) -> [NodeRole] {
        var roles: [NodeRole] = []
        if cluster.main?.machineID == machineID { roles.append(.main) }
        roles += cluster.workers.filter { $0.machineID == machineID }.map { .worker($0.id) }
        return roles
    }

    var allRoles: [NodeRole] {
        (cluster.main == nil ? [] : [.main]) + cluster.workers.map { .worker($0.id) }
    }

    func deployedAt(_ role: NodeRole) -> Date? {
        switch role {
        case .main: cluster.main?.deployedAt
        case .worker(let id): cluster.worker(id: id)?.deployedAt
        }
    }

    func deployedFingerprint(_ role: NodeRole) -> String? {
        switch role {
        case .main: cluster.main?.deployedFingerprint
        case .worker(let id): cluster.worker(id: id)?.deployedFingerprint
        }
    }

    func hasPendingChanges(_ role: NodeRole) -> Bool {
        guard let plan = plan(role) else { return false }
        return plan.fingerprint != deployedFingerprint(role)
    }

    func health(_ role: NodeRole) -> NodeHealth {
        guard let machine = machine(for: role), let plan = plan(role) else { return .notDeployed }
        if case .offline = connectivity[machine.id] ?? .unknown { return .unreachable }
        guard let runtime = nodeRuntime[role], runtime.lastUpdated != nil else {
            return deployedAt(role) == nil ? .notDeployed : .unknown
        }
        if runtime.containers.isEmpty { return deployedAt(role) == nil ? .notDeployed : .stopped }
        let expected = Set(plan.services)
        let running = runtime.containers.filter { expected.contains($0.service) && $0.isRunning }.count
        if running == expected.count { return .running }
        if running == 0 { return .stopped }
        return .degraded(running: running, total: expected.count)
    }

    var clusterHealthSummary: (label: String, color: Color) {
        guard cluster.main != nil else { return ("Not set up", .secondary) }
        let healths = allRoles.map(health)
        if healths.allSatisfy({ $0 == .running }) { return ("Healthy", .green) }
        if healths.contains(where: { $0 == .unreachable || $0 == .stopped }) { return ("Attention needed", .red) }
        if healths.contains(where: { if case .degraded = $0 { true } else { false } }) { return ("Degraded", .orange) }
        return ("Checking…", .secondary)
    }

    var portalURL: URL? {
        guard let main = cluster.main, main.portal.enabled else { return nil }
        return URL(string: "http://\(main.advertisedAddress):\(main.portal.httpPort)")
    }

    // MARK: - Machines

    /// Saves a machine. Passwords go to the Keychain, never to disk.
    func saveMachine(_ machine: Machine, password: String?) {
        if let password, !password.isEmpty {
            do {
                try Keychain.setPassword(password, account: machine.keychainAccount)
            } catch {
                alert = AlertItem(title: "Could Not Store Password", message: error.localizedDescription)
            }
        } else if !machine.needsStoredPassword {
            Keychain.deletePassword(account: machine.keychainAccount)
        }
        if let index = machines.firstIndex(where: { $0.id == machine.id }) {
            let previous = machines[index]
            machines[index] = machine
            if previous.host != machine.host || previous.port != machine.port || previous.user != machine.user
                || previous.auth != machine.auth || previous.identityFile != machine.identityFile {
                ssh.closeMaster(previous)
                connectivity[machine.id] = .unknown
            }
        } else {
            machines.append(machine)
            selection = .machine(machine.id)
        }
        Task { await poll(machine.id) }
    }

    func canRemoveMachine(_ id: UUID) -> Bool { roles(on: id).isEmpty }

    func removeMachine(_ id: UUID) {
        guard let machine = machine(id), canRemoveMachine(id) else { return }
        ssh.closeMaster(machine)
        Keychain.deletePassword(account: machine.keychainAccount)
        machines.removeAll { $0.id == id }
        connectivity[id] = nil
        hostSamples[id] = nil
        hostHistory[id] = nil
        containerUsage[id] = nil
        if selection == .machine(id) { selection = .overview }
    }

    /// Connects, gathers facts, and checks Docker with the machine's privilege mode.
    ///
    /// Throws only when the machine can't be reached. A failing privileged check
    /// (for example sudo wanting a password) is recorded in `privilegeError`.
    func inspect(_ machine: Machine) async throws -> MachineFacts {
        let preflight = try await ssh.runChecked(machine, script: RemoteScripts.preflight(installDirectory: machine.installDirectory), timeout: 30)
        var dockerOutput: String?
        var privilegeError: String?
        do {
            let result = try await ssh.run(machine, script: RemoteScripts.dockerCheck, privileged: true, timeout: 30)
            if result.succeeded {
                dockerOutput = result.stdout
            } else {
                privilegeError = result.failureMessage
            }
        } catch {
            if case .offline = Connectivity.from(error) { throw error }
            privilegeError = error.localizedDescription
        }
        var facts = RemoteScripts.facts(preflight: preflight.stdout, docker: dockerOutput)
        facts.privilegeError = privilegeError
        return facts
    }

    /// Re-runs the preflight for a saved machine and stores the result.
    func refreshFacts(_ id: UUID) async {
        guard let machine = machine(id) else { return }
        connectivity[id] = .checking
        do {
            let facts = try await inspect(machine)
            if let index = machines.firstIndex(where: { $0.id == id }) {
                machines[index].facts = facts
            }
            connectivity[id] = facts.privilegeError.map { .limited($0) } ?? .online
        } catch {
            connectivity[id] = Connectivity.from(error)
        }
    }

    /// Runs Docker as the SSH user (docker group) instead of through sudo.
    func useDockerGroup(_ id: UUID) {
        guard var machine = machine(id) else { return }
        let hasDeployedNodes = roles(on: id).contains { deployedAt($0) != nil }
        if hasDeployedNodes {
            // Keep the directory existing deployments live in.
            machine.privilege = .none
        } else {
            machine.adoptDockerGroup()
        }
        saveMachine(machine, password: nil)
        Task { await refreshFacts(id) }
    }

    /// Buildbarn projects on a machine that BB Manager didn't deploy.
    func unmanagedProjects(on machineID: UUID) -> [ComposeProject] {
        let managedDirectories = Set(roles(on: machineID).compactMap { plan($0)?.directory })
        return (discoveredProjects[machineID] ?? []).filter { !managedDirectories.contains($0.workingDirectory) }
    }

    /// Host ports a node would publish that another Buildbarn deployment on the same machine already uses.
    func portConflicts(_ role: NodeRole) -> [(port: Int, project: String)] {
        guard let plan = plan(role) else { return [] }
        let planned = Set(plan.hostPorts)
        return unmanagedProjects(on: plan.machine.id).flatMap { project in
            project.hostPorts.intersection(planned).sorted().map { (port: $0, project: project.name) }
        }
    }

    func installDocker(on id: UUID) {
        guard let machine = machine(id) else { return }
        runOperation(title: "Install Docker", machine: machine, script: RemoteScripts.installDocker) { [weak self] in
            await self?.refreshFacts(id)
        }
    }

    func openTerminal(_ machine: Machine) {
        var components = URLComponents()
        components.scheme = "ssh"
        components.host = machine.host
        components.user = machine.user.isEmpty ? nil : machine.user
        components.port = machine.port == 22 ? nil : machine.port
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Nodes

    func setUpMainNode(_ settings: MainNodeSettings) {
        cluster.main = settings
        selection = .mainNode
        deploy(.main)
    }

    func addWorker(_ worker: WorkerNode) {
        cluster.workers.append(worker)
        selection = .worker(worker.id)
        deploy(.worker(worker.id))
    }

    func deploy(_ role: NodeRole, pullImages: Bool = true) {
        guard let plan = plan(role) else {
            alert = AlertItem(title: "Cannot Deploy", message: role.isMain
                ? "The main node's machine is missing."
                : "Set up the main node before deploying workers.")
            return
        }
        let fingerprint = plan.fingerprint
        let verb = deployedAt(role) == nil ? "Deploy" : "Apply Changes to"
        runOperation(
            title: "\(verb) \(title(for: role))",
            machine: plan.machine,
            script: RemoteScripts.deploy(plan, pullImages: pullImages)
        ) { [weak self] in
            self?.markDeployed(role, fingerprint: fingerprint)
        }
    }

    /// Redeploys every node with pending changes: main first, then workers.
    func applyAllChanges() {
        let roles = allRoles.filter { hasPendingChanges($0) }
        guard let first = roles.first else { return }
        let plans = roles.compactMap { role in plan(role).map { (role, $0) } }
        let session = OperationSession(title: "Apply Changes to \(roles.count == 1 ? title(for: first) : "\(roles.count) Nodes")", machineName: Set(plans.map(\.1.machine.displayName)).sorted().joined(separator: ", "))
        operation = session
        session.task = Task { [weak self] in
            guard let self else { return }
            for (role, plan) in plans {
                guard !Task.isCancelled else { break }
                session.log.append("\n━━━ \(self.title(for: role)) on \(plan.machine.displayName) ━━━\n")
                do {
                    for try await chunk in self.ssh.stream(plan.machine, script: RemoteScripts.deploy(plan, pullImages: true), privileged: true) {
                        session.log.append(chunk)
                    }
                    // A cancelled stream ends without throwing; never record that as deployed.
                    try Task.checkCancellation()
                    self.markDeployed(role, fingerprint: plan.fingerprint)
                } catch {
                    if Task.isCancelled {
                        session.state = .cancelled
                    } else {
                        session.log.append("\n\(error.localizedDescription)\n")
                        session.state = .failed(error.localizedDescription)
                    }
                    await self.pollAll()
                    return
                }
            }
            session.state = Task.isCancelled ? .cancelled : .succeeded
            await self.pollAll()
        }
    }

    private func markDeployed(_ role: NodeRole, fingerprint: String) {
        switch role {
        case .main:
            cluster.main?.deployedFingerprint = fingerprint
            cluster.main?.deployedAt = Date()
        case .worker(let id):
            if let index = cluster.workers.firstIndex(where: { $0.id == id }) {
                cluster.workers[index].deployedFingerprint = fingerprint
                cluster.workers[index].deployedAt = Date()
            }
        }
    }

    func updateImages(_ role: NodeRole) {
        guard let plan = plan(role) else { return }
        runOperation(title: "Update \(title(for: role))", machine: plan.machine, script: RemoteScripts.deploy(plan, pullImages: true)) { [weak self] in
            self?.markDeployed(role, fingerprint: plan.fingerprint)
        }
    }

    /// Start/stop/restart without the console; failures surface as alerts.
    func compose(_ action: RemoteScripts.ComposeAction, role: NodeRole, service: String? = nil) {
        guard let plan = plan(role) else { return }
        busyNodes.insert(role)
        Task {
            defer { busyNodes.remove(role) }
            do {
                try await ssh.runChecked(plan.machine, script: RemoteScripts.compose(action, directory: plan.directory, service: service), privileged: true, timeout: 300)
            } catch {
                alert = AlertItem(title: "\(action.title) Failed", message: error.localizedDescription)
            }
            await poll(plan.machine.id)
        }
    }

    func removeNode(_ role: NodeRole, deleteData: Bool) {
        guard let plan = plan(role) else {
            forgetNode(role)
            return
        }
        runOperation(
            title: "Remove \(title(for: role))",
            machine: plan.machine,
            script: RemoteScripts.uninstall(directory: plan.directory, removeData: deleteData)
        ) { [weak self] in
            self?.forgetNode(role)
        }
    }

    /// Removes a node from the cluster model without touching the machine.
    func forgetNode(_ role: NodeRole) {
        switch role {
        case .main:
            cluster.main = nil
            if selection == .mainNode { selection = .overview }
        case .worker(let id):
            cluster.workers.removeAll { $0.id == id }
            if selection == .worker(id) { selection = .workers }
        }
        nodeRuntime[role] = nil
        metrics = metrics.filter { $0.key.role != role }
    }

    // MARK: - Taking over existing deployments

    /// Why a project can't be taken over right now, or nil if it can.
    func takeOverBlocker(on machineID: UUID) -> String? {
        if case .online = connectivity[machineID] ?? .unknown {} else {
            return "The machine must be online with working Docker access."
        }
        if let main = cluster.main, main.deployedAt != nil {
            return "This cluster already has a deployed main node on \(mainMachine?.displayName ?? "another machine"). Remove it first."
        }
        if operation?.isRunning == true {
            return "Another operation is running."
        }
        return nil
    }

    /// Makes a hand-made Buildbarn deployment fully managed by BB Manager in one step:
    /// survey it, import its settings, stop it, and deploy BB Manager's main node and
    /// worker in its place. If deploying fails or is cancelled, the new containers are
    /// removed and the old deployment is started again. Its files are never deleted.
    func takeOver(_ project: ComposeProject, on machineID: UUID) {
        guard let machine = machine(machineID) else { return }
        if let blocker = takeOverBlocker(on: machineID) {
            alert = AlertItem(title: "Cannot Take Over \(project.name)", message: blocker)
            return
        }
        let session = OperationSession(title: "Take Over \(project.name)", machineName: machine.displayName)
        operation = session
        session.task = Task { [weak self] in
            guard let self else { return }
            @MainActor func run(_ script: String) async throws {
                for try await chunk in self.ssh.stream(machine, script: script, privileged: true) {
                    session.log.append(chunk)
                }
                try Task.checkCancellation()
            }

            do {
                session.log.append("==> Reading \(project.name)'s settings from the running system\n")
                let survey = try await ssh.runChecked(machine, script: TakeoverSurvey.script(project: project.name), privileged: true, timeout: 120)
                let takeover = TakeoverSurvey.plan(output: survey.stdout, project: project, machine: machine, existing: cluster)
                for finding in takeover.findings { session.log.append("    • \(finding)\n") }
                for warning in takeover.warnings { session.log.append("    ! \(warning)\n") }
                if takeover.cacheBytes > 0 {
                    session.log.append("    • \(Format.bytes(takeover.cacheBytes)) of cached build data is not carried over; builds refill the cache.\n")
                }
                try Task.checkCancellation()

                // Import the settings.
                cluster.images = takeover.images
                cluster.main = takeover.main
                var roles: [NodeRole] = [.main]
                if let workerSettings = takeover.worker {
                    if let index = cluster.workers.firstIndex(where: { $0.machineID == machineID }) {
                        cluster.workers[index].settings = workerSettings
                        cluster.workers[index].fileOverrides = [:]
                        cluster.workers[index].deployedAt = nil
                        cluster.workers[index].deployedFingerprint = nil
                        roles.append(.worker(cluster.workers[index].id))
                    } else {
                        let node = WorkerNode(machineID: machineID, settings: workerSettings)
                        cluster.workers.append(node)
                        roles.append(.worker(node.id))
                    }
                }
                let plans = roles.compactMap { role in plan(role).map { (role, $0) } }
                guard plans.count == roles.count else {
                    throw SSHError.commandFailed(exitCode: 1, message: "Could not generate the new configuration.")
                }
                session.log.append("==> Imported the settings into BB Manager\n")

                do {
                    session.log.append("\n━━━ Stopping \(project.name) ━━━\n")
                    try await run(TakeoverSurvey.stopScript(takeover))
                    for (role, nodePlan) in plans {
                        session.log.append("\n━━━ Deploying \(title(for: role)) ━━━\n")
                        try await run(RemoteScripts.deploy(nodePlan, pullImages: true))
                        markDeployed(role, fingerprint: nodePlan.fingerprint)
                    }
                } catch {
                    let cancelled = Task.isCancelled
                    session.log.append("\n\(cancelled ? "Cancelled." : error.localizedDescription)\n\n━━━ Rolling back: starting \(project.name) again ━━━\n")
                    for (role, _) in plans { clearDeployed(role) }
                    // Not inherited: the rollback must run even after Cancel.
                    let rollback = TakeoverSurvey.rollbackScript(takeover, newDirectories: plans.map(\.1.directory))
                    let rollbackTask = Task { @MainActor in
                        for try await chunk in self.ssh.stream(machine, script: rollback, privileged: true) {
                            session.log.append(chunk)
                        }
                    }
                    do {
                        try await rollbackTask.value
                        session.log.append("\n\(project.name) is running again. The imported settings are kept in BB Manager so you can adjust them and try again.\n")
                    } catch {
                        session.log.append("\nRollback failed: \(error.localizedDescription)\nStart it by hand with: cd \(takeover.workingDirectory) && docker compose up -d\n")
                    }
                    session.state = cancelled ? .cancelled : .failed(error.localizedDescription)
                    await pollAll()
                    return
                }

                session.log.append("\n==> \(project.name) is now managed by BB Manager.\n    Its previous files and data are still in \(takeover.workingDirectory); delete that folder once you no longer need it.\n")
                session.state = .succeeded
                selection = .mainNode
            } catch {
                if Task.isCancelled {
                    session.state = .cancelled
                } else {
                    session.log.append("\n\(error.localizedDescription)\n")
                    session.state = .failed(error.localizedDescription)
                }
            }
            await pollAll()
        }
    }

    private func clearDeployed(_ role: NodeRole) {
        switch role {
        case .main:
            cluster.main?.deployedAt = nil
            cluster.main?.deployedFingerprint = nil
        case .worker(let id):
            if let index = cluster.workers.firstIndex(where: { $0.id == id }) {
                cluster.workers[index].deployedAt = nil
                cluster.workers[index].deployedFingerprint = nil
            }
        }
    }

    // MARK: - Operations console

    func runOperation(title: String, machine: Machine, script: String, privileged: Bool = true, onSuccess: @escaping @MainActor () async -> Void = {}) {
        let session = OperationSession(title: title, machineName: machine.displayName)
        operation = session
        session.task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in self.ssh.stream(machine, script: script, privileged: privileged) {
                    session.log.append(chunk)
                }
                if Task.isCancelled {
                    session.state = .cancelled
                } else {
                    session.state = .succeeded
                    await onSuccess()
                }
            } catch {
                if Task.isCancelled {
                    session.state = .cancelled
                } else {
                    session.log.append("\n\(error.localizedDescription)\n")
                    session.state = .failed(error.localizedDescription)
                }
            }
            await self.poll(machine.id)
        }
    }

    // MARK: - Monitoring

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll()
                let interval = UserDefaults.standard.double(forKey: AppDefaults.refreshInterval)
                try? await Task.sleep(for: .seconds(max(3, interval)))
            }
        }
    }

    func pollAll() async {
        isPolling = true
        await withTaskGroup(of: Void.self) { group in
            for machine in machines {
                let id = machine.id
                group.addTask { await self.poll(id) }
            }
        }
        recordClusterPoint()
        lastPoll = Date()
        isPolling = false
    }

    private func pollNodes(on machine: Machine) -> [(NodeRole, RemoteScripts.PollNode)] {
        roles(on: machine.id).compactMap { role in
            guard let plan = plan(role) else { return nil }
            return (role, RemoteScripts.PollNode(key: role.directoryName, directory: plan.directory, diagnostics: plan.diagnostics))
        }
    }

    func poll(_ machineID: UUID) async {
        guard let machine = machine(machineID), !inFlightPolls.contains(machineID) else { return }
        inFlightPolls.insert(machineID)
        defer { inFlightPolls.remove(machineID) }

        let nodes = pollNodes(on: machine)
        let script = RemoteScripts.poll(installDirectory: machine.installDirectory, nodes: nodes.map(\.1), includeMetrics: true)
        if (connectivity[machineID] ?? .unknown) == .unknown {
            connectivity[machineID] = .checking
        }
        do {
            let result = try await ssh.run(machine, script: script, privileged: true, timeout: 30)
            let now = Date()
            let output = PollOutput(result.stdout)
            // The script's last command may legitimately fail (grep with no matches),
            // so judge it by whether the sections came back, not by the exit status.
            guard output["loadavg"] != nil else {
                connectivity[machineID] = .limited("The status check failed: \(result.failureMessage)")
                return
            }
            connectivity[machineID] = .online
            if let projects = output.buildbarnProjects {
                discoveredProjects[machineID] = projects
            }

            let sample = output.host(previousCPU: hostSamples[machineID]?.cpu)
            hostSamples[machineID] = sample
            var history = hostHistory[machineID] ?? []
            history.append(HostPoint(date: now, cpu: sample.cpuUsage, memory: sample.memoryUsage, load1: sample.load1))
            hostHistory[machineID] = trimmed(history)
            containerUsage[machineID] = output.dockerStats

            for (role, node) in nodes {
                nodeRuntime[role] = NodeRuntime(containers: output.containers(nodeKey: node.key) ?? [], lastUpdated: now, error: nil)
                for endpoint in node.diagnostics {
                    let key = MetricsKey(role: role, service: endpoint.service)
                    if let snapshot = output.metrics(nodeKey: node.key, service: endpoint.service, timestamp: now) {
                        previousMetrics[key] = metrics[key]
                        metrics[key] = snapshot
                    } else {
                        previousMetrics[key] = nil
                        metrics[key] = nil
                    }
                }
            }
        } catch {
            connectivity[machineID] = Connectivity.from(error)
            for (role, _) in nodes {
                nodeRuntime[role, default: NodeRuntime()].error = error.localizedDescription
            }
        }
        // Re-inspect each machine once per launch so saved facts don't go stale
        // (Docker installed since, group membership changed, newer checks added).
        if !inspectedThisSession.contains(machineID), (connectivity[machineID] ?? .unknown) != .unknown {
            if case .offline = connectivity[machineID] ?? .unknown { return }
            inspectedThisSession.insert(machineID)
            await refreshFacts(machineID)
        }
    }

    private func trimmed<T>(_ points: [T]) -> [T] {
        let minutes = max(5, UserDefaults.standard.integer(forKey: AppDefaults.historyMinutes))
        let interval = max(3, UserDefaults.standard.double(forKey: AppDefaults.refreshInterval))
        let limit = Int(Double(minutes * 60) / interval) + 1
        return points.count > limit ? Array(points.suffix(limit)) : points
    }

    // MARK: Derived statistics

    var schedulerSummary: SchedulerSummary? {
        metrics[MetricsKey(role: .main, service: "scheduler")].flatMap(SchedulerSummary.init)
    }

    var previousSchedulerSummary: SchedulerSummary? {
        previousMetrics[MetricsKey(role: .main, service: "scheduler")].flatMap(SchedulerSummary.init)
    }

    var frontendSummary: FrontendSummary? {
        metrics[MetricsKey(role: .main, service: "frontend")].flatMap(FrontendSummary.init)
    }

    var previousFrontendSummary: FrontendSummary? {
        previousMetrics[MetricsKey(role: .main, service: "frontend")].flatMap(FrontendSummary.init)
    }

    func workerSummary(_ id: UUID) -> WorkerSummary? {
        metrics[MetricsKey(role: .worker(id), service: "worker")].flatMap(WorkerSummary.init)
    }

    private func recordClusterPoint() {
        guard cluster.main != nil else { return }
        var point = ClusterPoint(date: Date())
        if let current = schedulerSummary {
            point.queued = current.queued
            point.executing = current.executing
            point.executorSlots = current.executorSlots
            if let previous = previousSchedulerSummary {
                let seconds = current.timestamp.timeIntervalSince(previous.timestamp)
                point.actionsPerSecond = counterRate(previous: previous.tasksScheduled, current: current.tasksScheduled, seconds: seconds)
                let started = current.tasksStarted - previous.tasksStarted
                if started > 0 { point.queueSeconds = (current.queuedSecondsSum - previous.queuedSecondsSum) / started }
                let completed = current.tasksCompleted - previous.tasksCompleted
                if completed > 0 { point.executionSeconds = (current.executingSecondsSum - previous.executingSecondsSum) / completed }
            }
        }
        if let current = frontendSummary, let previous = previousFrontendSummary {
            let seconds = current.timestamp.timeIntervalSince(previous.timestamp)
            let hits = current.actionCacheHits - previous.actionCacheHits
            let misses = current.actionCacheMisses - previous.actionCacheMisses
            if hits >= 0, misses >= 0, hits + misses > 0 { point.cacheHitRate = hits / (hits + misses) }
            point.casReadBytesPerSecond = counterRate(previous: previous.chunkBytesRead, current: current.chunkBytesRead, seconds: seconds)
            point.casWriteBytesPerSecond = counterRate(previous: previous.chunkBytesWritten, current: current.chunkBytesWritten, seconds: seconds)
        }
        clusterHistory = trimmed(clusterHistory + [point])
    }

    /// Downloads the full metrics page (with histogram buckets) for the explorer.
    func fetchFullMetrics(role: NodeRole, service: String) async throws -> MetricsSnapshot {
        guard let plan = plan(role), let endpoint = plan.diagnostics.first(where: { $0.service == service }) else {
            throw SSHError.commandFailed(exitCode: 1, message: "Unknown metrics endpoint.")
        }
        let result = try await ssh.runChecked(plan.machine, script: RemoteScripts.fetchMetrics(port: endpoint.port), timeout: 30)
        guard !result.stdout.isEmpty else {
            throw SSHError.commandFailed(exitCode: 1, message: "\(service) returned no metrics. Is it running, and is curl or wget installed on \(plan.machine.displayName)?")
        }
        return PrometheusParser.parse(result.stdout)
    }

    /// Every metrics endpoint in the cluster, for the explorer's picker.
    var metricsEndpoints: [(key: MetricsKey, title: String)] {
        allRoles.flatMap { role -> [(key: MetricsKey, title: String)] in
            (plan(role)?.diagnostics ?? []).map { endpoint in
                (MetricsKey(role: role, service: endpoint.service), role.isMain ? endpoint.service : "\(title(for: role)) · \(endpoint.service)")
            }
        }
    }
}

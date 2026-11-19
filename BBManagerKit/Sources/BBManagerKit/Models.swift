import Foundation

// MARK: - Machines

/// How BB Manager authenticates against a remote machine.
public enum AuthMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Keys offered by ssh-agent, or whatever ~/.ssh/config specifies for the host.
    case sshAgent
    /// An explicit private key file.
    case identityFile
    /// A password stored in the macOS Keychain.
    case password

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sshAgent: "SSH Agent / ~/.ssh/config"
        case .identityFile: "Private Key File"
        case .password: "Password"
        }
    }
}

/// How privileged commands (Docker, writing to the install directory) are run.
public enum PrivilegeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case sudo
    case sudoWithPassword

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "None (root or docker group)"
        case .sudo: "sudo (passwordless)"
        case .sudoWithPassword: "sudo with password"
        }
    }
}

/// Facts collected from a machine by the preflight check.
public struct MachineFacts: Codable, Hashable, Sendable {
    public var osName: String?
    public var kernel: String?
    public var architecture: String?
    public var cpuCount: Int?
    public var memoryBytes: Int64?
    public var primaryAddress: String?
    public var dockerVersion: String?
    public var composeVersion: String?
    public var hasFuse: Bool?
    public var hasHTTPClient: Bool?
    /// `uname -s`: "Linux" or "Darwin".
    public var kernelName: String?
    public var diskTotalBytes: Int64?
    public var diskAvailableBytes: Int64?
    public var isRoot: Bool?
    public var passwordlessSudo: Bool?
    /// The SSH user can talk to Docker without sudo (root or member of the docker group).
    public var dockerWithoutSudo: Bool?
    /// The SSH user can create the install directory without sudo.
    public var installDirectoryWritable: Bool?
    public var homeDirectory: String?
    /// Why the privileged check failed (for example sudo wanting a password).
    public var privilegeError: String?
    public var checkedAt: Date

    public init(checkedAt: Date = Date()) {
        self.checkedAt = checkedAt
    }

    public var dockerReady: Bool { dockerVersion?.isEmpty == false && composeVersion?.isEmpty == false }

    /// macOS machines run workers natively (no Docker) and cannot host the main node.
    public var isMacOS: Bool { kernelName == "Darwin" }

    /// Buildbarn's release asset suffix for this machine, e.g. `darwin_arm64`.
    public var buildbarnPlatform: String? {
        guard isMacOS else { return nil }
        switch architecture {
        case "arm64": return "darwin_arm64"
        case "x86_64": return "darwin_amd64"
        default: return nil
        }
    }

    /// sudo is unusable without a password, but Docker works directly (docker group).
    public var shouldUseDockerGroup: Bool {
        !isMacOS && isRoot != true && passwordlessSudo == false && dockerWithoutSudo == true
    }

    /// Install directory to use when switching to the docker group, if the current one needs root.
    public func dockerGroupInstallDirectory(current: String) -> String? {
        guard installDirectoryWritable == false, let home = homeDirectory, home.hasPrefix("/"), home != "/" else { return nil }
        return (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/buildbarn"
    }
}

public struct Machine: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    public var auth: AuthMethod
    public var identityFile: String
    public var privilege: PrivilegeMode
    public var installDirectory: String
    public var facts: MachineFacts?

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        user: String = "",
        auth: AuthMethod = .sshAgent,
        identityFile: String = "",
        privilege: PrivilegeMode = .sudo,
        installDirectory: String = "/opt/buildbarn",
        facts: MachineFacts? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.identityFile = identityFile
        self.privilege = privilege
        self.installDirectory = installDirectory
        self.facts = facts
    }

    public var displayName: String { name.isEmpty ? host : name }

    public var sshDestination: String { user.isEmpty ? host : "\(user)@\(host)" }

    /// Keychain account under which this machine's password is stored.
    public var keychainAccount: String { id.uuidString }

    public var needsStoredPassword: Bool { auth == .password || privilege == .sudoWithPassword }

    /// Switches to running Docker as the SSH user (docker group), moving the install
    /// directory into the home directory when the current one needs root.
    public mutating func adoptDockerGroup() {
        privilege = .none
        if let directory = facts?.dockerGroupInstallDirectory(current: installDirectory) {
            installDirectory = directory
        }
    }

    /// macOS workers live in the home directory and run as the SSH user, but they are
    /// installed as launchd daemons (the only kind macOS lets reach the local network),
    /// which needs administrator rights.
    public mutating func adoptNativeMode() {
        adoptNativePrivileges()
        if let directory = facts?.dockerGroupInstallDirectory(current: installDirectory) {
            installDirectory = directory
        }
    }

    /// Picks a privilege mode that can install launchd daemons, if the current one can't.
    public mutating func adoptNativePrivileges() {
        if facts?.isRoot == true {
            privilege = .none
        } else if facts?.passwordlessSudo == true {
            if privilege == .none { privilege = .sudo }
        } else if privilege != .sudoWithPassword {
            privilege = .sudoWithPassword
        }
    }

    /// Validation messages for the editor. Empty means valid.
    public var validationErrors: [String] {
        var errors: [String] = []
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if trimmedHost.isEmpty { errors.append("Host is required.") }
        if trimmedHost.hasPrefix("-") || trimmedHost.contains(" ") { errors.append("Host contains invalid characters.") }
        if user.hasPrefix("-") || user.contains(" ") || user.contains("@") { errors.append("User contains invalid characters.") }
        if !(1...65535).contains(port) { errors.append("Port must be between 1 and 65535.") }
        if auth == .identityFile && identityFile.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Choose a private key file.")
        }
        if !installDirectory.hasPrefix("/") || installDirectory == "/" {
            errors.append("Install directory must be an absolute path other than /.")
        }
        return errors
    }
}

// MARK: - Cluster configuration

/// Container images used by the cluster. Buildbarn publishes timestamped tags only.
public struct ImageSet: Codable, Hashable, Sendable {
    public var storage: String
    public var scheduler: String
    public var worker: String
    public var runnerInstaller: String
    public var portal: String
    public var postgres: String

    public init(storage: String, scheduler: String, worker: String, runnerInstaller: String, portal: String, postgres: String) {
        self.storage = storage
        self.scheduler = scheduler
        self.worker = worker
        self.runnerInstaller = runnerInstaller
        self.portal = portal
        self.postgres = postgres
    }

    /// Versions matching buildbarn/bb-deployments as of November 2026.
    public static let recommended = ImageSet(
        storage: "ghcr.io/buildbarn/bb-storage:20261102T091443Z-ca3d8b4",
        scheduler: "ghcr.io/buildbarn/bb-scheduler:20261102T094740Z-c9ba98c",
        worker: "ghcr.io/buildbarn/bb-worker:20261102T094740Z-c9ba98c",
        runnerInstaller: "ghcr.io/buildbarn/bb-runner-installer:20261102T094740Z-c9ba98c",
        portal: "ghcr.io/buildbarn/bb-portal:20261102T100250Z-a4bd618",
        postgres: "docker.io/postgres:18-alpine"
    )
}

public struct StorageSettings: Codable, Hashable, Sendable {
    /// Number of bb-storage shards on the main node.
    public var shards: Int = 1
    /// Size of the chunk store (CAS) per shard.
    public var casSizeGiB: Double = 32
    public var actionCacheSizeMiB: Double = 256
    public var chunkMappingSizeMiB: Double = 64
    public var fileSystemAccessCacheSizeMiB: Double = 64
    /// Keep data across restarts.
    public var persistent: Bool = true
    /// Number of FindMissingBlobs results the frontend caches.
    public var existenceCacheSize: Int = 1_000_000

    public init() {}
}

public struct SchedulerSettings: Codable, Hashable, Sendable {
    public var defaultExecutionTimeoutSeconds: Int = 1800
    public var maximumExecutionTimeoutSeconds: Int = 7200
    public var platformQueueWithNoWorkersTimeoutSeconds: Int = 900

    public init() {}
}

public struct PortalSettings: Codable, Hashable, Sendable {
    public var enabled: Bool = true
    public var httpPort: Int = 8081
    public var besPort: Int = 8082
    public var companyName: String = "Buildbarn"
    public var databasePassword: String = PortalSettings.randomPassword()

    public init() {}

    public static func randomPassword(length: Int = 24) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

public struct MainNodeSettings: Codable, Hashable, Sendable {
    public var machineID: UUID
    /// Address that workers and Bazel clients use to reach the main node.
    public var advertisedAddress: String
    public var frontendPort: Int = 8980
    public var schedulerWorkerPort: Int = 8983
    /// Host port of storage shard 0; shard N listens on base + N.
    public var storageBasePort: Int = 8991
    public var maximumMessageSizeMiB: Int = 4
    public var storage = StorageSettings()
    public var scheduler = SchedulerSettings()
    public var portal = PortalSettings()
    /// Files the user customised, keyed by relative path.
    public var fileOverrides: [String: String] = [:]
    public var deployedFingerprint: String?
    public var deployedAt: Date?

    public init(machineID: UUID, advertisedAddress: String) {
        self.machineID = machineID
        self.advertisedAddress = advertisedAddress
    }
}

public enum WorkerKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Virtual build directory backed by FUSE. Most efficient; needs /dev/fuse.
    case fuse
    /// Classic build directory populated with hardlinks from a local cache.
    case hardlinking
    /// bb_worker and bb_runner run directly on macOS under launchd, without Docker,
    /// hardlinking inputs from a local cache into a real build directory.
    case native
    /// Native macOS worker whose build directory is a virtual file system that
    /// bb_worker serves over NFSv4, so inputs are fetched only when read.
    case nativeNFSv4

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fuse: "FUSE (recommended)"
        case .hardlinking: "Hardlinking"
        case .native: "Hardlinking (native macOS)"
        case .nativeNFSv4: "NFSv4 (native macOS, recommended)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .fuse: "FUSE"
        case .hardlinking: "Hardlinking"
        case .native: "macOS · Hardlinking"
        case .nativeNFSv4: "macOS · NFSv4"
        }
    }

    /// Runs directly on macOS under launchd rather than in Docker.
    public var isNative: Bool { self == .native || self == .nativeNFSv4 }

    /// Serves inputs lazily from a virtual file system (FUSE or NFSv4).
    public var isVirtual: Bool { self == .fuse || self == .nativeNFSv4 }

    /// Kinds a machine can run, recommended first.
    public static func available(onMacOS: Bool) -> [WorkerKind] {
        onMacOS ? [.nativeNFSv4, .native] : [.fuse, .hardlinking]
    }
}

public struct PlatformProperty: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

public struct WorkerSettings: Codable, Hashable, Sendable {
    public var kind: WorkerKind = .fuse
    /// Number of actions run in parallel.
    public var concurrency: Int = 8
    public var instanceNamePrefix: String = ""
    /// Image providing the execution environment for actions.
    public var runnerImage: String = WorkerSettings.recommendedRunnerImage
    public var platformProperties: [PlatformProperty] = [PlatformProperty(name: "OSFamily", value: "linux")]
    /// Adds `container-image: docker://<runnerImage>` to the platform properties.
    public var advertiseContainerImage: Bool = true
    /// FUSE: size of the local CAS read cache. Hardlinking: size of the file cache.
    public var localCacheSizeGiB: Double = 16
    /// Hardlinking only: maximum number of cached files.
    public var maximumCacheFileCount: Int = 100_000
    /// FUSE only: scratch space each action may use for outputs.
    public var filePoolPerActionGiB: Double = 1
    public var inputDownloadConcurrency: Int = 10
    public var outputUploadConcurrency: Int = 11

    public init() {}

    public static let recommendedRunnerImage =
        "ghcr.io/catthehacker/ubuntu:act-22.04@sha256:dd7654ffb01d5b7b54b23b9ce928a1f7f2d08c7b3d7e320b6574b55d7ccde78b"

    /// Platform properties as advertised to the scheduler, sorted by name.
    public var effectivePlatformProperties: [(name: String, value: String)] {
        var props = platformProperties
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) }
        if advertiseContainerImage && !props.contains(where: { $0.name == "container-image" }) {
            props.append((name: "container-image", value: "docker://" + runnerImage))
        }
        return props.sorted { $0.name < $1.name }
    }
}

public struct WorkerNode: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var machineID: UUID
    public var settings: WorkerSettings
    public var fileOverrides: [String: String] = [:]
    public var deployedFingerprint: String?
    public var deployedAt: Date?

    public init(id: UUID = UUID(), machineID: UUID, settings: WorkerSettings) {
        self.id = id
        self.machineID = machineID
        self.settings = settings
    }
}

public struct ClusterConfiguration: Codable, Hashable, Sendable {
    public var name: String = "Buildbarn"
    public var images: ImageSet = .recommended
    public var main: MainNodeSettings?
    public var workers: [WorkerNode] = []
    public var workerDefaults = WorkerSettings()

    public init() {}

    public func worker(id: UUID) -> WorkerNode? { workers.first { $0.id == id } }
}

// MARK: - Node roles

public enum NodeRole: Hashable, Codable, Sendable {
    case main
    case worker(UUID)

    public var isMain: Bool { if case .main = self { true } else { false } }

    public var workerID: UUID? { if case .worker(let id) = self { id } else { nil } }

    /// Directory below the machine's install directory.
    public var directoryName: String { isMain ? "main" : "worker" }

    public var composeProjectName: String { isMain ? "buildbarn-main" : "buildbarn-worker" }
}

import BBManagerKit
import SwiftUI

// MARK: - Main node

struct MainSettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let main = Binding($model.cluster.main) {
            Form {
                MainNodeSections(main: main, machine: model.mainMachine)
                Section {
                    ApplyChangesRow(role: .main)
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct MainNodeSections: View {
    @Binding var main: MainNodeSettings
    var machine: Machine?
    var showNetwork = true

    var body: some View {
        if showNetwork {
            Section {
                TextField("Advertised Address", text: $main.advertisedAddress, prompt: Text("10.0.0.10 or buildbarn.internal"))
                IntegerField(title: "Frontend Port", value: $main.frontendPort, range: 1...65535,
                             help: "Bazel connects here for remote execution and caching.")
                IntegerField(title: "Scheduler Port for Workers", value: $main.schedulerWorkerPort, range: 1...65535)
                IntegerField(title: "Storage Port", value: $main.storageBasePort, range: 1...65535,
                             help: main.storage.shards > 1 ? "Shard N listens on this port + N." : "Workers read and write blobs here.")
                IntegerField(title: "Maximum Message Size", value: $main.maximumMessageSizeMiB, unit: "MiB", range: 1...64)
            } header: {
                Text("Network")
            } footer: {
                Text("Workers and Bazel clients must be able to resolve and reach the advertised address. The frontend, scheduler and storage ports accept unauthenticated traffic, so keep them on a trusted network.")
            }
        }

        Section {
            IntegerField(title: "Storage Shards", value: $main.storage.shards, range: 1...16,
                         help: "Each shard is a separate bb-storage process with its own copy of the sizes below.")
            NumberField(title: "Content Addressable Storage", value: $main.storage.casSizeGiB, unit: "GiB", range: 1...16384, step: 8,
                        help: "Holds build inputs and outputs. The bigger, the more cache hits.")
            NumberField(title: "Action Cache", value: $main.storage.actionCacheSizeMiB, unit: "MiB", range: 16...65536, step: 64)
            NumberField(title: "Chunk Mapping Storage", value: $main.storage.chunkMappingSizeMiB, unit: "MiB", range: 16...65536, step: 16)
            NumberField(title: "File System Access Cache", value: $main.storage.fileSystemAccessCacheSizeMiB, unit: "MiB", range: 16...65536, step: 16)
            Toggle(isOn: $main.storage.persistent) {
                Text("Keep Data Across Restarts")
                Text("Persist block indexes so restarts don't drop the cache.")
            }
            IntegerField(title: "Frontend Existence Cache", value: $main.storage.existenceCacheSize, unit: "entries", range: 1000...100_000_000, step: 100_000)
            DiskEstimateRow(required: storageBytes, available: machine?.facts?.diskAvailableBytes)
        } header: {
            Text("Storage")
        } footer: {
            Text("Changing a size or the number of shards clears the cache when the change is applied.")
        }

        Section("Scheduler") {
            MinutesField(title: "Default Action Timeout", seconds: $main.scheduler.defaultExecutionTimeoutSeconds, range: 1...1440)
            MinutesField(title: "Maximum Action Timeout", seconds: $main.scheduler.maximumExecutionTimeoutSeconds, range: 1...2880)
            MinutesField(title: "Fail Queued Actions Without Workers After", seconds: $main.scheduler.platformQueueWithNoWorkersTimeoutSeconds, range: 1...1440)
        }

        Section {
            Toggle("Enable bb-portal", isOn: $main.portal.enabled)
            if main.portal.enabled {
                IntegerField(title: "Web Port", value: $main.portal.httpPort, range: 1...65535)
                IntegerField(title: "Build Event Service Port", value: $main.portal.besPort, range: 1...65535)
                TextField("Organization Name", text: $main.portal.companyName)
            }
        } header: {
            Text("Portal")
        } footer: {
            Text("bb-portal is the web UI for browsing builds, actions, the scheduler queue and cache contents. It runs with a PostgreSQL database on the main node.")
        }
    }

    private var storageBytes: Int64 {
        let s = main.storage
        let perShard = s.casSizeGiB * 1024 * 1.0125 + (s.actionCacheSizeMiB + s.chunkMappingSizeMiB + s.fileSystemAccessCacheSizeMiB) * 1.05
        return Int64(perShard * Double(max(1, s.shards)) * 1024 * 1024)
    }
}

struct MinutesField: View {
    var title: String
    @Binding var seconds: Int
    var range: ClosedRange<Int>

    var body: some View {
        IntegerField(
            title: title,
            value: Binding(get: { max(1, seconds / 60) }, set: { seconds = $0 * 60 }),
            unit: "min",
            range: range,
            step: 5
        )
    }
}

struct DiskEstimateRow: View {
    var required: Int64
    var available: Int64?

    var body: some View {
        LabeledContent("Disk Space Needed") {
            HStack(spacing: 6) {
                if let available, required > available {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(Format.bytes(required))
                if let available {
                    Text("of \(Format.bytes(available)) free").foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
        }
    }
}

struct ApplyChangesRow: View {
    @Environment(AppModel.self) private var model
    let role: NodeRole

    var body: some View {
        HStack {
            if model.hasPendingChanges(role) {
                Label("Changes are saved but not deployed.", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            } else {
                Label("Deployed configuration is up to date.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.deployedAt(role) == nil ? "Deploy" : "Apply Changes") { model.deploy(role) }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasPendingChanges(role) && model.deployedAt(role) != nil)
        }
    }
}

// MARK: - Workers

struct WorkerNodeSettingsForm: View {
    @Environment(AppModel.self) private var model
    let index: Int

    var body: some View {
        @Bindable var model = model
        let worker = model.cluster.workers[index]
        Form {
            WorkerSettingsSections(settings: $model.cluster.workers[index].settings, machine: model.machine(worker.machineID))
            Section {
                ApplyChangesRow(role: .worker(worker.id))
            }
        }
        .formStyle(.grouped)
    }
}

struct WorkerSettingsSections: View {
    @Binding var settings: WorkerSettings
    var machine: Machine?

    private var isNative: Bool { settings.kind.isNative }

    var body: some View {
        Section {
            Picker("Build Directory", selection: $settings.kind) {
                ForEach(WorkerKind.available(onMacOS: machine?.facts?.isMacOS == true || isNative)) { Text($0.label).tag($0) }
            }
            if settings.kind == .fuse, machine?.facts?.hasFuse == false {
                Label("This machine has no /dev/fuse. Use a hardlinking worker or install FUSE.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            IntegerField(title: "Concurrency", value: $settings.concurrency, unit: "actions", range: 1...512,
                         help: machine?.facts?.cpuCount.map { "This machine has \($0) CPUs." } ?? "Number of actions run in parallel.")
            TextField("Instance Name Prefix", text: $settings.instanceNamePrefix, prompt: Text("empty: default instance"))
        } header: {
            Text("Execution")
        } footer: {
            switch settings.kind {
            case .fuse:
                Text("FUSE workers expose inputs lazily through a virtual file system. They are the most efficient but need privileged containers and /dev/fuse.")
            case .hardlinking:
                Text("Hardlinking workers copy inputs from a local cache into a real directory. Use them where FUSE is not available.")
            case .nativeNFSv4:
                Text("bb_worker and bb_runner run directly on this Mac as launchd daemons; build actions run as the SSH user. The build directory is a virtual file system that bb_worker serves over NFSv4, so inputs are fetched only when an action reads them. No kernel extension is needed.")
            case .native:
                Text("bb_worker and bb_runner run directly on this Mac as launchd daemons, downloaded from Buildbarn's release that matches the cluster. Build actions run as the SSH user. Inputs are hardlinked from a local cache.")
            }
        }

        Section {
            if !isNative {
                ImageField(title: "Runner Image", text: $settings.runnerImage)
                Toggle(isOn: $settings.advertiseContainerImage) {
                    Text("Advertise container-image Property")
                    Text("Adds container-image=docker://<runner image> to the worker's platform.")
                }
            }
            PlatformPropertiesEditor(properties: $settings.platformProperties)
        } header: {
            Text("Execution Environment")
        } footer: {
            Text(isNative
                 ? "Actions run directly on this Mac with the tools installed there, such as Xcode. Bazel's exec properties must match the platform properties exactly."
                 : "Actions run inside the runner image. Bazel's exec properties must match the platform properties exactly; the Overview shows matching .bazelrc lines.")
        }

        Section {
            Toggle(isOn: Binding(
                get: { settings.sharedPoolConcurrency > 0 },
                set: { settings.sharedPoolSlots = $0 ? max(1, settings.concurrency) : nil }
            )) {
                Text("Join the Shared Pool")
                Text("Also take actions whose platform is exactly \(Self.sharedPoolPlatform).")
            }
            if settings.sharedPoolConcurrency > 0 {
                IntegerField(title: "Shared Pool Slots", value: Binding(
                    get: { settings.sharedPoolConcurrency },
                    set: { settings.sharedPoolSlots = $0 }
                ), unit: "actions", range: 1...512,
                help: "In addition to the worker's own slots, so a busy worker may run both at once.")
            }
        } header: {
            Text("Shared Pool")
        } footer: {
            Text("The shared pool is for actions that run on any worker, whatever its OS, such as compiles through a wrapper that picks the worker's own compiler. The worker keeps its own platform for actions that need its OS.")
        }

        Section("Caching") {
            NumberField(title: settings.kind.isVirtual ? "Local Blob Cache" : "Local File Cache", value: $settings.localCacheSizeGiB, unit: "GiB", range: 1...4096, step: 4)
            if !settings.kind.isVirtual {
                IntegerField(title: "Maximum Cached Files", value: $settings.maximumCacheFileCount, range: 100...100_000_000, step: 10_000)
            } else {
                NumberField(title: "Scratch Space per Action", value: $settings.filePoolPerActionGiB, unit: "GiB", range: 0.125...256, step: 0.5,
                            help: "Outputs an action may write before it fails. Reserved for every concurrent action.")
            }
            IntegerField(title: "Parallel Input Downloads", value: $settings.inputDownloadConcurrency, range: 1...256)
            IntegerField(title: "Parallel Output Uploads", value: $settings.outputUploadConcurrency, range: 1...256)
            DiskEstimateRow(required: diskBytes, available: machine?.facts?.diskAvailableBytes)
        }
    }

    static let sharedPoolPlatform = WorkerSettings.sharedPoolProperties.map { "\($0.name)=\($0.value)" }.joined(separator: ",")

    private var diskBytes: Int64 {
        var gib = settings.localCacheSizeGiB * 1.0125
        if settings.kind.isVirtual {
            gib += settings.filePoolPerActionGiB * Double(settings.totalSlots)
        }
        return Int64(gib * 1024 * 1024 * 1024)
    }
}

struct PlatformPropertiesEditor: View {
    @Binding var properties: [PlatformProperty]

    var body: some View {
        LabeledContent("Platform Properties") {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach($properties) { $property in
                    HStack(spacing: 6) {
                        TextField("Name", text: $property.name, prompt: Text("name"))
                            .frame(width: 130)
                        Text("=").foregroundStyle(.secondary)
                        TextField("Value", text: $property.value, prompt: Text("value"))
                            .frame(minWidth: 120)
                        Button {
                            properties.removeAll { $0.id == property.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove property")
                    }
                    .labelsHidden()
                }
                Button {
                    properties.append(PlatformProperty(name: "", value: ""))
                } label: {
                    Label("Add Property", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

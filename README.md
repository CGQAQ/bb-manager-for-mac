# BB Manager

A native macOS app (SwiftUI) for deploying and running a [Buildbarn](https://github.com/buildbarn) remote execution cluster on your own Linux machines over SSH.

- **Machines**: add any Linux host you can reach over SSH. The app checks the OS, CPUs, memory, disk, Docker, Compose and FUSE, and can install Docker for you.
- **Main node**: one click deploys bb-storage (frontend and storage shards), bb-scheduler and bb-portal with PostgreSQL. From the app you can start, stop and restart services, stream logs, update images, or remove the node.
- **Workers**: bb-worker and bb-runner in FUSE or hardlinking mode, with per-worker concurrency, cache sizes, runner image and platform properties.
- **Statistics**: throughput, executing and queued actions, queue and execution latency, action cache hit rate, CAS traffic, per-stage worker timings, CPU and memory for each component and host, plus a metrics explorer for every Prometheus series.
- **Configuration**: storage sizes, shards, timeouts, ports, portal settings and image versions. Any generated file can be edited by hand in the Files tab. Pending changes are tracked and applied with **Apply Changes**.
- **Mac look and feel**: sidebar split view, toolbar actions, grouped forms, Swift Charts, a Settings window, keyboard shortcuts and a menu bar extra.

## Requirements

- macOS 14 or later. Building needs Xcode 16 or later (developed with Xcode 27).
- Remote machines: Linux with Docker Engine and the Compose plugin, `curl` or `wget` (for metrics), and either root, passwordless sudo, or sudo with a password. FUSE workers also need `/dev/fuse`.

## Build and run

```bash
open BBManager.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project BBManager.xcodeproj -scheme BBManager -configuration Release -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Release/BB Manager.app"
```

The core library has its own tests:

```bash
cd BBManagerKit && swift test
```

## How it works

### SSH

BB Manager runs the system `/usr/bin/ssh`, so `~/.ssh/config`, ssh-agent, keys, `ProxyJump` and `known_hosts` all work as they do in Terminal. Each machine keeps one multiplexed connection (`ControlMaster`, with sockets in `/tmp/bbm-<uid>`), which makes the 10-second status polling cheap. New host keys are accepted on first contact (`StrictHostKeyChecking=accept-new`), and a changed host key is refused.

Passwords live in the login Keychain. For password logins, the app binary acts as its own `SSH_ASKPASS` helper and reads the password from the Keychain. For sudo, the password is written to `sudo -S` on stdin and never placed on a command line.

Each remote script is passed as one quoted argument to `sh -c`, with `sudo -n` or `sudo -S` in front when needed. Configuration files are embedded in the script as base64.

### Layout on the machines

| Node | Directory | Services |
|------|-----------|----------|
| Main | `<install dir>/main` (default `/opt/buildbarn/main`) | `frontend`, `storage-N`, `scheduler`, `portal`, `postgres` |
| Worker | `<install dir>/worker` | `runner-installer`, `worker`, `runner` |

Each directory is a Docker Compose project with `docker-compose.yml`, `config/*.jsonnet` and `volumes/`. The generated configuration follows [buildbarn/bb-deployments](https://github.com/buildbarn/bb-deployments) (docker-compose flavour, November 2026 images), adapted so workers can run on other machines.

| Port | Bound to | Purpose |
|------|----------|---------|
| 8980 | all interfaces | Frontend: remote execution and cache for Bazel |
| 8983 | all interfaces | Scheduler: worker registration |
| 8991+N | all interfaces | Storage shard N: blob reads and writes from workers |
| 8081 / 8082 | all interfaces | bb-portal web UI / Build Event Service |
| 8984 | 127.0.0.1 | Scheduler BuildQueueState |
| 9980–9999 | 127.0.0.1 | Prometheus metrics, read over SSH |

All ports are configurable in the app. Buildbarn's gRPC endpoints are unauthenticated in this setup, so run the cluster on a trusted network.

Changing storage sizes or the shard count clears the cache on the next deploy (a layout stamp in `volumes/` detects this). Worker cache size changes do the same for the worker's local cache.

### Using the cluster from Bazel

The Overview page shows `.bazelrc` lines that match the cluster's address and the workers' platform properties, for example:

```
build:bb --remote_executor=grpc://10.0.0.10:8980
build:bb --remote_default_exec_properties=OSFamily=linux
build:bb --remote_default_exec_properties=container-image=docker://ghcr.io/catthehacker/ubuntu:act-22.04@sha256:…
build:bb --bes_backend=grpc://10.0.0.10:8082
```

## Project structure

```
BBManager.xcodeproj        Xcode project (app target, uses synchronized folders)
BBManager/                 SwiftUI app
  BBManagerApp.swift       Entry point, askpass helper, scenes, menu commands
  Model/                   AppModel (state, deployment, polling) and support types
  Views/                   Sidebar, overview, machines, nodes, statistics, configuration
BBManagerKit/              Swift package with the UI-independent core
  SSHClient.swift          OpenSSH process runner (run and stream)
  ConfigGenerator.swift    docker-compose and Jsonnet generation
  RemoteScripts.swift      Preflight, deploy, compose, logs, uninstall, poll
  Prometheus.swift         Prometheus text-format parser
  Monitoring.swift         Poll output, host stats, Buildbarn metric summaries
scripts/make-icon.swift    Regenerates the app icon
```

State is saved to `~/Library/Application Support/BB Manager/state.json`.

### Launch arguments for testing

`-BBMStateFile <path>` uses another state file. Debug builds also accept `-BBMInitialSelection main|workers|statistics|configuration|worker|machine`, `-BBMInitialTab Services|Logs|Settings|Files` and `-BBMInitialSheet addMachine|editMachine|addWorker`. `BBM_SAMPLE_STATE=/tmp/demo.json swift test` writes a demo state file.

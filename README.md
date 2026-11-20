# BB Manager

A native macOS app (SwiftUI) for deploying and running a [Buildbarn](https://github.com/buildbarn) remote execution cluster on your own Linux machines over SSH.

- **Machines**: add any Linux host you can reach over SSH. The app checks the OS, CPUs, memory, disk, Docker, Compose and FUSE, and can install Docker for you.
- **Main node**: one click deploys bb-storage (frontend and storage shards), bb-scheduler and bb-portal with PostgreSQL. From the app you can start, stop and restart services, stream logs, update images, or remove the node.
- **Workers**: bb-worker and bb-runner in FUSE or hardlinking mode, with per-worker concurrency, cache sizes, runner image and platform properties.
- **Statistics**: throughput, executing and queued actions, queue and execution latency, action cache hit rate, CAS traffic, per-stage worker timings, CPU and memory for each component and host, plus a metrics explorer for every Prometheus series.
- **Configuration**: storage sizes, shards, timeouts, ports, portal settings and image versions. Any generated file can be edited by hand in the Files tab. Pending changes are tracked and applied with **Apply Changes**.
- **Profiles**: keep several clusters, each with its own machines, and switch between them from the top of the sidebar or the Profile menu. Switching changes only what the app shows and manages; nodes keep running on their machines. A profile can be duplicated with its machines and saved passwords.
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

### Package as a DMG

```bash
scripts/build-dmg.sh
```

This builds a universal (Apple silicon and Intel) Release app and writes `dist/BB-Manager-<version>.dmg`, which contains the app and an Applications shortcut for drag-to-install. The build log goes to `build/build-dmg.log`.

By default the app is signed ad hoc. It runs on the Mac that built it. On other Macs, Gatekeeper blocks the first launch: right-click the app and choose **Open**, or allow it under System Settings > Privacy & Security. To distribute it properly, sign with a Developer ID certificate and notarize:

```bash
xcrun notarytool store-credentials bbmanager-notary
```

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=bbmanager-notary scripts/build-dmg.sh
```

`VERSION`, `BUILD_NUMBER` and `DMG_NAME` override the version, build number and file name.

### Releases on GitHub

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs whenever a GitHub release is published. On a `macos-26` runner it runs the tests, builds the DMG, and attaches `BB-Manager-<tag>.dmg` and its `.sha256` checksum to the release.

To release, publish a release in the GitHub web UI (Releases > Draft a new release), or use the CLI:

```bash
gh release create v1.0.0 --generate-notes
```

- A tag such as `v1.2.3` sets the app version to 1.2.3. The build number is the workflow run number. A suffix like `v1.3.0-beta.1` stays in the file name, but the app version is 1.3.0.
- **Actions > Release > Run workflow** rebuilds the DMG for an existing tag and replaces the attached files. Leave the tag empty for a dry run: the DMG is kept only as a workflow artifact.
- Without extra secrets, the DMG is signed ad hoc, the same as a local build. To ship a Developer ID signed and notarized DMG, add these repository secrets:

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE_P12` | Base64 of your "Developer ID Application" certificate exported as .p12 (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | Password of that .p12 |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | Apple ID, team ID and an [app-specific password](https://support.apple.com/102654) for notarization |

### Tests

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
scripts/build-dmg.sh       Builds the Release app and packages it as a DMG
.github/workflows/         Release workflow that attaches the DMG to GitHub releases
scripts/make-icon.swift    Regenerates the app icon
```

State is saved to `~/Library/Application Support/BB Manager/state.json`.

### Launch arguments for testing

`-BBMStateFile <path>` uses another state file. Debug builds also accept `-BBMInitialSelection main|workers|statistics|configuration|worker|machine`, `-BBMInitialTab Services|Logs|Settings|Files` and `-BBMInitialSheet addMachine|editMachine|addWorker`. `BBM_SAMPLE_STATE=/tmp/demo.json swift test` writes a demo state file.

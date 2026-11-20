import Foundation

/// Scripts for native macOS workers: bb_worker and bb_runner, downloaded from
/// Buildbarn's GitHub releases and run as launchd daemons.
///
/// macOS Local Network privacy makes connections to other machines fail with "no
/// route to host" for launchd agents and for daemons that run as a regular user
/// (`UserName`); only root daemons are exempt (Apple TN3179). So bb_worker, which
/// talks to the scheduler and storage, runs as root, while bb_runner, which runs the
/// build actions, runs as the SSH user. Installing them needs administrator rights.
public enum LaunchdScripts {
    public static let services = ["runner", "worker"]

    public static func label(_ service: String) -> String { "dev.bbmanager.bb-\(service)" }

    /// Placeholders in the generated property lists, filled in at install time.
    public static let userPlaceholder = "__BBM_USER__"
    public static let groupPlaceholder = "__BBM_GROUP__"
    public static let homePlaceholder = "__BBM_HOME__"

    /// Shell helpers shared by every script.
    static let functions = """
    LD=system
    DAEMONS=/Library/LaunchDaemons
    bbm_loaded() { launchctl print "$LD/$1" >/dev/null 2>&1; }
    bbm_unload() {
      launchctl bootout "$LD/$1" 2>/dev/null || true
      i=0
      # On SIGTERM, bb_worker deregisters from the scheduler and unmounts its NFSv4
      # build directory. That is quick, but slow when the scheduler is unreachable.
      while bbm_loaded "$1" && [ $i -lt 520 ]; do sleep 0.25; i=$((i+1)); done
    }
    bbm_load() {
      if bbm_loaded "$1"; then launchctl kickstart "$LD/$1"; else launchctl bootstrap "$LD" "$DAEMONS/$1.plist"; fi
    }
    bbm_status() {
      out=$(launchctl print "$LD/dev.bbmanager.bb-$1" 2>/dev/null) || out=""
      version=$(cat "$2/bin/.version" 2>/dev/null)
      if [ -z "$out" ]; then
        st=stopped; detail="Not loaded"
      else
        st=$(printf '%s\\n' "$out" | awk -F' = ' '$1 ~ /^[[:space:]]*state$/ {print $2; exit}')
        pid=$(printf '%s\\n' "$out" | awk -F' = ' '$1 ~ /^[[:space:]]*pid$/ {print $2; exit}')
        code=$(printf '%s\\n' "$out" | awk -F' = ' '$1 ~ /^[[:space:]]*last exit code$/ {print $2; exit}')
        if [ "$st" = running ]; then detail="Running (pid $pid)"; else detail="Not running (last exit code ${code:-unknown})"; fi
      fi
      printf '{"Name":"bb-%s","Service":"%s","State":"%s","Status":"%s","Image":"bb_%s %s"}\\n' "$1" "$1" "${st:-unknown}" "$detail" "$1" "$version"
    }
    # Removes a launch agent installed by earlier versions of BB Manager.
    bbm_remove_agent() {
      ouid=$(id -u "$2" 2>/dev/null) || return 0
      for domain in "gui/$ouid" "user/$ouid"; do
        if launchctl print "$domain/$1" >/dev/null 2>&1; then
          echo "    Removing the launch agent $1 from an earlier version"
          launchctl bootout "$domain/$1" 2>/dev/null || true
          i=0
          while launchctl print "$domain/$1" >/dev/null 2>&1 && [ $i -lt 520 ]; do sleep 0.25; i=$((i+1)); done
        fi
      done
      ohome=$(dscl . -read "/Users/$2" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
      if [ -n "$ohome" ]; then rm -f "$ohome/Library/LaunchAgents/$1.plist"; fi
    }
    """

    /// Fails unless the script runs as root (directly or through sudo).
    static let requireRoot = """
    if [ "$(id -u)" != 0 ]; then
      echo "error: native macOS workers run as launchd daemons, which needs administrator rights. Edit this machine and set its privileges to sudo."
      exit 1
    fi
    """

    /// Status lines in `docker compose ps --format json` shape, so they parse as `ContainerStatus`.
    /// Prints nothing when the node was never installed.
    public static func statusSection(directory: String) -> String {
        let dir = Shell.quote(directory)
        return """
        if [ -f \(dir)/bin/.version ] && command -v launchctl >/dev/null 2>&1; then
        \(functions)
        \(services.map { "bbm_status \($0) \(dir)" }.joined(separator: "\n"))
        fi
        """
    }

    public static func deploy(_ plan: NodePlan) -> String {
        let release = plan.nativeRelease ?? NativeRelease(tag: "", binaries: [])
        var script = """
        set -e
        exec 2>&1
        if [ "$(uname -s)" != Darwin ]; then echo "error: native workers run on macOS only."; exit 1; fi
        \(requireRoot)
        DIR=\(Shell.quote(plan.directory))
        if [ ${#DIR} -gt 90 ]; then echo "error: $DIR is too long; macOS limits socket paths to 104 bytes. Choose a shorter install directory."; exit 1; fi
        # Build actions run as the SSH user, not as root.
        OWNER="${SUDO_USER:-$(id -un)}"
        OWNER_GROUP=$(id -gn "$OWNER")
        OWNER_HOME=$(dscl . -read "/Users/$OWNER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        echo "==> Writing configuration to $DIR (builds run as $OWNER)"
        mkdir -p "$DIR/config" "$DIR/launchd" "$DIR/bin" "$DIR/logs"
        cd "$DIR"

        """
        for file in plan.files {
            let encoded = Data(file.content.utf8).base64EncodedString()
            let tmp = Shell.quote(file.path + ".bbm-tmp")
            script += "printf '%s' '\(encoded)' | base64 -D > \(tmp) && mv \(tmp) \(Shell.quote(file.path))\n"
        }
        script += """
        case "$(uname -m)" in
          arm64) ARCH=darwin_arm64 ;;
          x86_64) ARCH=darwin_amd64 ;;
          *) echo "error: unsupported CPU $(uname -m)"; exit 1 ;;
        esac
        TAG=\(Shell.quote(release.tag))
        if [ -z "$TAG" ]; then echo "error: could not determine the Buildbarn version from the worker image."; exit 1; fi
        if [ "$(cat bin/.version 2>/dev/null)" != "$TAG $ARCH" ]; then
          echo "==> Downloading Buildbarn $TAG for $ARCH"
          for b in \(release.binaries.joined(separator: " ")); do
            curl -fsSL --retry 3 --connect-timeout 20 -o "bin/$b.download" "https://github.com/buildbarn/bb-remote-execution/releases/download/$TAG/$b.$ARCH"
            chmod 0755 "bin/$b.download"
            xattr -c "bin/$b.download" 2>/dev/null || true
            codesign --force --sign - "bin/$b.download" 2>/dev/null || true
            mv -f "bin/$b.download" "bin/$b"
            echo "    $b ($(du -h "bin/$b" | cut -f1 | tr -d ' '))"
          done
          printf '%s %s\\n' "$TAG" "$ARCH" > bin/.version
        else
          echo "==> Buildbarn $TAG for $ARCH is already installed"
        fi
        \(functions)
        echo "==> Stopping running services"
        \(services.reversed().map { "bbm_unload \(label($0))\nbbm_remove_agent \(label($0)) \"$OWNER\"" }.joined(separator: "\n"))
        echo "==> Preparing directories"
        \(plan.prepareScript)
        chown -R "$OWNER:$OWNER_GROUP" "$DIR"
        # The log keeps the stopped worker's shutdown messages; show only what the new one writes.
        LOG_START=0
        if [ -f logs/worker.log ]; then LOG_START=$(wc -c < logs/worker.log | tr -d ' '); fi
        echo "==> Starting launchd daemons"
        \(services.map { installDaemon(label($0)) }.joined(separator: "\n"))
        sleep 4
        echo "==> Status"
        failed=0
        for svc in \(services.joined(separator: " ")); do
          line=$(bbm_status "$svc" "$DIR")
          echo "    $line"
          case "$line" in *'"State":"running"'*) ;; *) failed=1 ;; esac
        done
        echo "==> Worker log since start"
        new_log=$(tail -c +$((${LOG_START:-0} + 1)) logs/worker.log 2>/dev/null | tail -n 20)
        if [ -n "$new_log" ]; then printf '%s\\n' "$new_log"; else echo "    Nothing logged; bb_worker logs only problems."; fi
        if [ $failed = 1 ]; then
          echo "error: a service is not running. Its log is in $DIR/logs."
          exit 1
        fi
        echo "==> Done"
        """
        return script
    }

    /// Installs a daemon's property list with the user filled in; launchd requires
    /// /Library/LaunchDaemons entries to be owned by root and not group-writable.
    static func installDaemon(_ label: String) -> String {
        """
        sed -e "s|\(userPlaceholder)|$OWNER|g" -e "s|\(groupPlaceholder)|$OWNER_GROUP|g" -e "s|\(homePlaceholder)|$OWNER_HOME|g" "launchd/\(label).plist" > "$DAEMONS/\(label).plist"
        chown root:wheel "$DAEMONS/\(label).plist"
        chmod 0644 "$DAEMONS/\(label).plist"
        launchctl bootstrap "$LD" "$DAEMONS/\(label).plist"
        """
    }

    public static func action(_ action: RemoteScripts.ComposeAction, directory: String, service: String?) -> String {
        let targets = (service.map { [$0] } ?? services).map(label)
        let body: String
        switch action {
        case .start, .pull:
            body = targets.map { "bbm_load \($0)" }.joined(separator: "\n")
        case .stop:
            body = targets.reversed().map { "bbm_unload \($0)" }.joined(separator: "\n")
        case .restart:
            body = targets.map { "if bbm_loaded \($0); then launchctl kickstart -k \"$LD/\($0)\"; else bbm_load \($0); fi" }.joined(separator: "\n")
        }
        return """
        set -e
        exec 2>&1
        \(requireRoot)
        \(functions)
        \(body)
        sleep 1
        \(services.map { "bbm_status \($0) \(Shell.quote(directory))" }.joined(separator: "\n"))
        """
    }

    public static func logs(directory: String, service: String?, tail: Int, follow: Bool) -> String {
        let files = (service.map { [$0] } ?? services).map { "logs/\($0).log" }.joined(separator: " ")
        return """
        exec 2>&1
        cd \(Shell.quote(directory)) || exit 1
        exec tail -n \(max(1, tail))\(follow ? " -F" : "") \(files)
        """
    }

    public static func uninstall(directory: String, removeData: Bool) -> String {
        var script = """
        exec 2>&1
        \(requireRoot)
        \(functions)
        OWNER="${SUDO_USER:-$(id -un)}"
        echo "==> Stopping and removing launchd daemons"
        \(services.reversed().map { "bbm_unload \(label($0))\nrm -f \"$DAEMONS/\(label($0)).plist\"\nbbm_remove_agent \(label($0)) \"$OWNER\"" }.joined(separator: "\n"))
        \(ConfigGenerator.unmountBuildDirectory(directory))

        """
        if removeData {
            script += """
            echo "==> Deleting \(directory)"
            rm -rf \(Shell.quote(directory))

            """
        }
        script += "echo \"==> Done\"\n"
        return script
    }
}

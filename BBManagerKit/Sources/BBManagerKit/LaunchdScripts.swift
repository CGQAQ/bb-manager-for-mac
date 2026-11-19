import Foundation

/// Scripts for native macOS workers: bb_worker and bb_runner run as launchd agents
/// of the SSH user, from binaries downloaded from Buildbarn's GitHub releases.
public enum LaunchdScripts {
    public static let services = ["runner", "worker"]

    public static func label(_ service: String) -> String { "dev.bbmanager.bb-\(service)" }

    /// Shell helpers shared by every script. `$LD` is the launchd domain: the GUI
    /// session when someone is logged in at the Mac, otherwise the background user domain.
    static let functions = """
    u=$(id -u)
    if launchctl print "gui/$u" >/dev/null 2>&1; then LD="gui/$u"; else LD="user/$u"; fi
    AGENTS="$HOME/Library/LaunchAgents"
    bbm_loaded() { launchctl print "$LD/$1" >/dev/null 2>&1; }
    bbm_unload() {
      launchctl bootout "$LD/$1" 2>/dev/null || true
      i=0
      while bbm_loaded "$1" && [ $i -lt 40 ]; do sleep 0.25; i=$((i+1)); done
    }
    bbm_load() {
      if bbm_loaded "$1"; then launchctl kickstart "$LD/$1"; else launchctl bootstrap "$LD" "$AGENTS/$1.plist"; fi
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
        DIR=\(Shell.quote(plan.directory))
        echo "==> Writing configuration to $DIR"
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
        \(services.reversed().map { "bbm_unload \(label($0))" }.joined(separator: "\n"))
        echo "==> Preparing directories"
        \(plan.prepareScript)
        echo "==> Starting services with launchd ($LD)"
        mkdir -p "$AGENTS"
        \(services.map { "cp \"launchd/\(label($0)).plist\" \"$AGENTS/\(label($0)).plist\"\nlaunchctl bootstrap \"$LD\" \"$AGENTS/\(label($0)).plist\"" }.joined(separator: "\n"))
        sleep 4
        echo "==> Status"
        failed=0
        for svc in \(services.joined(separator: " ")); do
          line=$(bbm_status "$svc" "$DIR")
          echo "    $line"
          case "$line" in *'"State":"running"'*) ;; *) failed=1 ;; esac
        done
        echo "==> Recent worker log"
        tail -n 20 logs/worker.log 2>/dev/null || true
        if [ $failed = 1 ]; then
          echo "error: a service is not running. Its log is in $DIR/logs."
          exit 1
        fi
        echo "==> Done"
        """
        return script
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
        \(functions)
        echo "==> Stopping and removing launchd agents"
        \(services.reversed().map { "bbm_unload \(label($0))\nrm -f \"$AGENTS/\(label($0)).plist\"" }.joined(separator: "\n"))

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

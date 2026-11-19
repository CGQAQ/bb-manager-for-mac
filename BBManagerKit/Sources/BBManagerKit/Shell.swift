import Foundation

public enum Shell {
    /// Quotes a string for POSIX shells (also safe for bash, zsh and fish).
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A remote command line plus the data to write to its standard input.
    public struct RemoteInvocation: Sendable, Equatable {
        public var command: String
        public var input: Data
    }

    /// Builds what runs a POSIX script under `sh` on a remote machine, optionally through sudo.
    ///
    /// The command line is short and fixed; the script travels on standard input,
    /// preceded by the sudo password when one is needed. Long command lines break SSH
    /// connection sharing on macOS: ssh hands the command to the master connection
    /// over a Unix socket, and when the master has not read all of it yet, passing the
    /// terminal's file descriptors fails with "mm_send_fd: sendmsg: Message too long".
    ///
    /// The remote bootstrap reads the script into a variable and runs it with `sh -c`,
    /// so nothing in it is interpreted by the remote login shell, and the script itself
    /// runs with standard input at /dev/null.
    public static func remoteInvocation(script: String, privilege: PrivilegeMode?, password: String? = nil) -> RemoteInvocation {
        let body = "exec </dev/null\n" + script
        let bootstrap: String
        var input = Data()
        switch privilege {
        case .none?, nil:
            bootstrap = #"s=$(cat) && exec sh -c "$s""#
        case .sudo?:
            bootstrap = #"s=$(cat) && exec sudo -n sh -c "$s""#
        case .sudoWithPassword?:
            // `read` takes only the first line, leaving the script for `cat`.
            bootstrap = #"IFS= read -r p; s=$(cat); printf "%s\n" "$p" | sudo -k -S -p "" sh -c "$s""#
            input.append(Data(((password ?? "") + "\n").utf8))
        }
        input.append(Data(body.utf8))
        return RemoteInvocation(command: "sh -c " + quote(bootstrap), input: input)
    }

    /// Shell snippet that sets `$DC` to the available Docker Compose command.
    public static let detectCompose = """
    if docker compose version >/dev/null 2>&1; then DC='docker compose'
    elif command -v docker-compose >/dev/null 2>&1; then DC='docker-compose'
    else DC=''
    fi
    """
}

import Foundation

public enum Shell {
    /// Quotes a string for POSIX shells (also safe for bash, zsh and fish).
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wraps a POSIX script so it runs under `sh`, optionally through sudo.
    ///
    /// The script is passed as a single argument, so nothing it contains is
    /// interpreted by the remote login shell. Standard input is reserved for
    /// the sudo password and never reaches the script.
    public static func remoteCommand(script: String, privilege: PrivilegeMode?) -> String {
        let body = "exec </dev/null\n" + script
        let wrapped = "sh -c " + quote(body)
        switch privilege {
        case .none?, nil:
            return wrapped
        case .sudo?:
            return "sudo -n " + wrapped
        case .sudoWithPassword?:
            return "sudo -k -S -p '' " + wrapped
        }
    }

    /// Shell snippet that sets `$DC` to the available Docker Compose command.
    public static let detectCompose = """
    if docker compose version >/dev/null 2>&1; then DC='docker compose'
    elif command -v docker-compose >/dev/null 2>&1; then DC='docker-compose'
    else DC=''
    fi
    """
}

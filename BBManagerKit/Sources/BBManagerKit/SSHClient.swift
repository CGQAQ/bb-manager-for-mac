import Foundation

public struct SSHResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { exitCode == 0 }

    /// Best human-readable explanation of a failure.
    public var failureMessage: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return String(out.suffix(2000)) }
        return "The command exited with status \(exitCode)."
    }
}

public enum SSHError: LocalizedError, Sendable, Equatable {
    case launchFailed(String)
    case timedOut(Int)
    case connectionFailed(String)
    case sudoPasswordRequired
    case sudoFailed(String)
    case passwordMissing
    case scriptTooLarge
    case commandFailed(exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            "Could not start ssh: \(message)"
        case .timedOut(let seconds):
            "The remote command did not finish within \(seconds) seconds."
        case .connectionFailed(let message):
            message.isEmpty ? "Could not connect over SSH." : message
        case .sudoPasswordRequired:
            "sudo asked for a password. Choose “sudo with password” and store the password, or allow passwordless sudo for this user."
        case .sudoFailed(let message):
            "sudo failed: \(message)"
        case .passwordMissing:
            "No password is stored in the Keychain for this machine. Edit the machine and enter its password."
        case .scriptTooLarge:
            "The generated remote script is too large to send in one command."
        case .commandFailed(let code, let message):
            message.isEmpty ? "The remote command exited with status \(code)." : message
        }
    }
}

public struct SSHOptions: Sendable, Equatable {
    public var sshPath: String = "/usr/bin/ssh"
    public var connectTimeout: Int = 10
    public var controlPersistSeconds: Int = 120
    /// Additional `-o` options, e.g. `ProxyJump=bastion`.
    public var extraOptions: [String] = []
    /// Executable invoked through SSH_ASKPASS for password authentication.
    public var askpassExecutable: String?

    public init() {}
}

/// Runs commands on remote machines through the system OpenSSH client.
///
/// Using `/usr/bin/ssh` means the user's ~/.ssh/config, keys, ssh-agent,
/// known_hosts and ProxyJump setups work unchanged. Connections are
/// multiplexed with ControlMaster so repeated polling stays cheap.
public final class SSHClient: @unchecked Sendable {
    public static let shared = SSHClient()

    /// Environment variable that makes the app act as an SSH_ASKPASS helper.
    public static let askpassAccountVariable = "BBM_ASKPASS_ACCOUNT"

    private let lock = NSLock()
    private var _options = SSHOptions()
    public var passwordProvider: @Sendable (String) -> String? = { Keychain.password(account: $0) }

    public var options: SSHOptions {
        get { lock.withLock { _options } }
        set { lock.withLock { _options = newValue } }
    }

    public init() {
        // Writing a sudo password to an ssh process that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    public static var controlDirectory: String { "/tmp/bbm-\(getuid())" }

    private func prepareControlDirectory() {
        let path = Self.controlDirectory
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        chmod(path, 0o700)
    }

    // MARK: Command construction

    public func arguments(for machine: Machine, remoteCommand: String?, options: SSHOptions) -> [String] {
        var args: [String] = ["-T"]
        func opt(_ value: String) { args += ["-o", value] }
        opt("ConnectTimeout=\(options.connectTimeout)")
        opt("ServerAliveInterval=15")
        opt("ServerAliveCountMax=3")
        opt("StrictHostKeyChecking=accept-new")
        // Keep the default LogLevel: ERROR hides "connection timed out" and DNS failures.
        opt("ControlMaster=auto")
        opt("ControlPath=\(Self.controlDirectory)/%C")
        opt("ControlPersist=\(options.controlPersistSeconds)")
        if machine.auth == .password {
            opt("NumberOfPasswordPrompts=1")
        } else {
            opt("BatchMode=yes")
        }
        if machine.auth == .identityFile {
            let path = (machine.identityFile as NSString).expandingTildeInPath
            args += ["-i", path]
            opt("IdentitiesOnly=yes")
        }
        for extra in options.extraOptions where !extra.trimmingCharacters(in: .whitespaces).isEmpty {
            opt(extra.trimmingCharacters(in: .whitespaces))
        }
        if machine.port != 22 {
            args += ["-p", String(machine.port)]
        }
        args.append("--")
        args.append(machine.sshDestination)
        if let remoteCommand {
            args.append(remoteCommand)
        }
        return args
    }

    func environment(for machine: Machine, options: SSHOptions) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: Self.askpassAccountVariable)
        if machine.auth == .password, let askpass = options.askpassExecutable {
            env["SSH_ASKPASS"] = askpass
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env[Self.askpassAccountVariable] = machine.keychainAccount
        }
        return env
    }

    private func makeProcess(_ machine: Machine, script: String, privileged: Bool) throws -> (Process, Data) {
        let options = self.options
        let privilege: PrivilegeMode? = privileged ? machine.privilege : nil
        // The remote side passes the script to `sh -c` as one argument; Linux caps that at 128 KiB.
        guard script.utf8.count < 120_000 else { throw SSHError.scriptTooLarge }

        var password: String?
        if privilege == .sudoWithPassword {
            guard let stored = passwordProvider(machine.keychainAccount), !stored.isEmpty else {
                throw SSHError.passwordMissing
            }
            password = stored
        }
        if machine.auth == .password, passwordProvider(machine.keychainAccount)?.isEmpty ?? true {
            throw SSHError.passwordMissing
        }
        let invocation = Shell.remoteInvocation(script: script, privilege: privilege, password: password)

        prepareControlDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: options.sshPath)
        process.arguments = arguments(for: machine, remoteCommand: invocation.command, options: options)
        process.environment = environment(for: machine, options: options)
        return (process, invocation.input)
    }

    /// Writes the script to ssh's standard input and closes it.
    ///
    /// Runs off the caller's thread: a script larger than the pipe buffer blocks the
    /// write until ssh has connected and started reading.
    private static func feed(_ pipe: Pipe, _ data: Data) {
        let handle = pipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    // MARK: Running

    /// Runs a script and collects its output.
    ///
    /// Throws for SSH-level failures (cannot connect, sudo refused, timeout).
    /// A non-zero exit status of the script itself is returned in the result.
    public func run(_ machine: Machine, script: String, privileged: Bool = false, timeout: TimeInterval = 60) async throws -> SSHResult {
        let (process, stdinData) = try makeProcess(machine, script: script, privileged: privileged)
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        let collector = OutputCollector()

        let result: SSHResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SSHResult, Error>) in
                collector.onFinish = { outcome in continuation.resume(with: outcome) }
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        collector.finishStream(stdout: true)
                    } else {
                        collector.append(data, stdout: true)
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        collector.finishStream(stdout: false)
                    } else {
                        collector.append(data, stdout: false)
                    }
                }
                process.terminationHandler = { proc in
                    collector.setExit(proc.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.fail(SSHError.launchFailed(error.localizedDescription))
                    return
                }
                Self.feed(inPipe, stdinData)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        collector.markTimedOut(Int(timeout))
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Self.checkTransportErrors(result, privileged: privileged ? machine.privilege : nil, host: machine.host)
        return result
    }

    /// Runs a script and throws unless it exits successfully.
    @discardableResult
    public func runChecked(_ machine: Machine, script: String, privileged: Bool = false, timeout: TimeInterval = 60) async throws -> SSHResult {
        let result = try await run(machine, script: script, privileged: privileged, timeout: timeout)
        guard result.succeeded else {
            throw SSHError.commandFailed(exitCode: result.exitCode, message: result.failureMessage)
        }
        return result
    }

    /// Streams the combined stdout/stderr of a script, line-buffered.
    ///
    /// The stream finishes normally when the script exits with status 0 and
    /// throws `SSHError.commandFailed` otherwise. Cancelling the consuming
    /// task terminates the remote command.
    public func stream(_ machine: Machine, script: String, privileged: Bool = false) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process: Process
            let stdinData: Data
            do {
                (process, stdinData) = try makeProcess(machine, script: script, privileged: privileged)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let outPipe = Pipe()
            let inPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = outPipe
            process.standardInput = inPipe

            let state = StreamState()
            let privilege = privileged ? machine.privilege : nil
            state.onDone = { status, tail in
                if status == 0 {
                    continuation.finish()
                } else if status == 255 {
                    continuation.finish(throwing: SSHError.connectionFailed(tail.isEmpty ? "Could not connect to \(machine.host) over SSH." : tail))
                } else if let sudoError = Self.sudoError(in: tail, privilege: privilege) {
                    continuation.finish(throwing: sudoError)
                } else {
                    continuation.finish(throwing: SSHError.commandFailed(exitCode: status, message: "The command exited with status \(status)."))
                }
            }
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let rest = state.buffer.flush() {
                        state.remember(rest)
                        continuation.yield(rest)
                    }
                    state.markEOF()
                } else {
                    for text in state.buffer.append(data) {
                        state.remember(text)
                        continuation.yield(text)
                    }
                }
            }
            process.terminationHandler = { proc in state.setExit(proc.terminationStatus) }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: SSHError.launchFailed(error.localizedDescription))
                return
            }
            Self.feed(inPipe, stdinData)
        }
    }

    /// Closes the multiplexed master connection, e.g. after editing a machine.
    public func closeMaster(_ machine: Machine) {
        let options = self.options
        let process = Process()
        process.executableURL = URL(fileURLWithPath: options.sshPath)
        var args = arguments(for: machine, remoteCommand: nil, options: options)
        args.insert(contentsOf: ["-O", "exit"], at: 0)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Error mapping

    static func sudoError(in text: String, privilege: PrivilegeMode?) -> SSHError? {
        guard let privilege, privilege != .none else { return nil }
        let lower = text.lowercased()
        // Classic sudo and sudo-rs (the default since Ubuntu 25.10) word these differently.
        if lower.contains("sudo: a password is required")
            || lower.contains("sudo: a terminal is required")
            || lower.contains("sudo: interactive authentication is required") {
            return .sudoPasswordRequired
        }
        if lower.contains("incorrect password") || lower.contains("sorry, try again")
            || lower.contains("authentication failed") || lower.contains("incorrect authentication attempt") {
            return .sudoFailed("The stored password was rejected.")
        }
        if lower.contains("is not in the sudoers file") || lower.contains("not allowed to execute")
            || lower.contains("i'm afraid i can't do that") {
            return .sudoFailed("This user is not allowed to use sudo.")
        }
        return nil
    }

    static func checkTransportErrors(_ result: SSHResult, privileged: PrivilegeMode?, host: String) throws {
        if result.exitCode == 255 {
            let message = result.stderr
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.connectionFailed(message.isEmpty ? "Could not connect to \(host) over SSH." : message)
        }
        if !result.succeeded, let error = sudoError(in: result.stderr, privilege: privileged) {
            throw error
        }
    }
}

// MARK: - Helpers

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutDone = false
    private var stderrDone = false
    private var exitStatus: Int32?
    private var timedOut: Int?
    private var finished = false
    var onFinish: ((Result<SSHResult, Error>) -> Void)?

    func append(_ data: Data, stdout isStdout: Bool) {
        lock.withLock {
            if isStdout { stdout.append(data) } else { stderr.append(data) }
        }
    }

    func finishStream(stdout isStdout: Bool) {
        lock.lock()
        if isStdout { stdoutDone = true } else { stderrDone = true }
        completeIfReady()
    }

    func setExit(_ status: Int32) {
        lock.lock()
        exitStatus = status
        completeIfReady()
    }

    func markTimedOut(_ seconds: Int) {
        lock.withLock { timedOut = seconds }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = onFinish
        lock.unlock()
        callback?(.failure(error))
    }

    /// Must be called with the lock held; releases it.
    private func completeIfReady() {
        guard !finished, stdoutDone, stderrDone, let status = exitStatus else {
            lock.unlock()
            return
        }
        finished = true
        let outcome: Result<SSHResult, Error>
        if let timedOut {
            outcome = .failure(SSHError.timedOut(timedOut))
        } else {
            outcome = .success(SSHResult(
                exitCode: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            ))
        }
        let callback = onFinish
        lock.unlock()
        callback?(outcome)
    }
}

private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    let buffer = LineBuffer()
    private var eof = false
    private var exitStatus: Int32?
    private var done = false
    private var tail: [String] = []
    var onDone: ((Int32, String) -> Void)?

    func remember(_ text: String) {
        lock.withLock {
            tail.append(text)
            if tail.count > 20 { tail.removeFirst(tail.count - 20) }
        }
    }

    func markEOF() {
        lock.lock()
        eof = true
        finishIfReady()
    }

    func setExit(_ status: Int32) {
        lock.lock()
        exitStatus = status
        finishIfReady()
    }

    private func finishIfReady() {
        guard !done, eof, let status = exitStatus else {
            lock.unlock()
            return
        }
        done = true
        let callback = onDone
        let text = tail.joined().replacingOccurrences(of: "\r", with: "")
        lock.unlock()
        callback?(status, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Splits a byte stream into chunks that end on line boundaries so that
/// multi-byte UTF-8 sequences are never cut in half.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else {
                if pending.count > 65_536 {
                    let text = String(decoding: pending, as: UTF8.self)
                    pending.removeAll()
                    return [text]
                }
                return []
            }
            let chunk = pending[pending.startIndex...lastNewline]
            let text = String(decoding: chunk, as: UTF8.self)
            pending = Data(pending[pending.index(after: lastNewline)...])
            return [text]
        }
    }

    func flush() -> String? {
        lock.withLock {
            guard !pending.isEmpty else { return nil }
            let text = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            return text
        }
    }
}

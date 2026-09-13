import Foundation

/// Add an account by running the CLI's own login against a throwaway config directory.
///
/// claudex owns no OAuth code: no loopback listener, no PKCE verifier, no client id to keep
/// current under the provider's feet. The CLI does the whole flow, writes its credential into a
/// directory nothing else reads, and claudex adopts what lands there. The account the CLI is
/// signed into is never touched, so a sign-in cannot log the user out of the session they are
/// in the middle of.
enum SandboxedLogin {
    /// Long enough for a browser round trip including a password manager and an MFA prompt.
    static let timeout: TimeInterval = 300
    private static let pollInterval: TimeInterval = 1

    struct Result {
        let account: Account
        let wasAlreadyKnown: Bool
    }

    /// Runs the login and stores whatever it produces as an inactive account. Inactive on
    /// purpose: adding an account is not a request to switch to it, and switching is one click
    /// away in the panel.
    @MainActor
    static func run(_ kind: ProviderKind, into store: AccountStore) async throws -> Result {
        Log.write("login: starting \(kind.rawValue)")
        let directory = try makeDirectory()
        Log.write("login: config dir \(directory.path)")
        // Claude Code derives its Keychain service name from the config directory, so the login
        // leaves an item behind under a name claudex cannot compute. Recording what existed
        // beforehand is how it is found afterwards, and how it gets cleaned up.
        let servicesBefore = (kind == .claude) ? ((try? ClaudeCLIKeychain.credentialServices()) ?? []) : []

        defer { clean(directory, kind: kind, servicesBefore: servicesBefore) }

        let login = try launch(kind, in: directory)
        defer { login.stop() }
        let credentials = try await waitForCredentials(
            kind, in: directory, servicesBefore: servicesBefore, login: login
        )
        Log.write("login: got credentials, fingerprint \(credentials.refreshFingerprint)")

        // The gating lives in `fetchIdentity`: an API key or an account with no claude.ai
        // subscription is rejected there, before anything is written to the store.
        let identity: Identity
        do {
            identity = try await Providers.of(kind).fetchIdentity(credentials)
            Log.write("login: identity \(identity.email) / \(identity.plan)")
        } catch {
            Log.write("login: identity failed — \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
            throw error
        }

        if let existing = store.existing(matching: identity, kind: kind) {
            try store.storeCredentials(credentials, for: existing)
            Log.write("login: updated existing account \(existing.label)")
            return Result(account: existing, wasAlreadyKnown: true)
        }

        let label = AccountLabel.suggested(for: identity, kind: kind, store: store)
        let isFirst = store.accounts(for: kind).isEmpty
        let account = try store.add(identity: identity, kind: kind, label: label, credentials: credentials)
        // A later account is added inactive — adding is not a request to switch — but the first
        // one has nothing to be switched away from, and signing in here is how the CLI is meant
        // to get its credentials now, so it takes over straight away.
        if isFirst {
            try await Switcher.activate(account, in: store)
            Log.write("login: \(account.label) is the first \(kind.rawValue) account, signed the CLI into it")
        }
        Log.write("login: added \(account.label); store now has \(store.accounts(for: kind).count) \(kind.rawValue) account(s)")
        return Result(account: account, wasAlreadyKnown: false)
    }

    // MARK: - Running the CLI

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "claudex-login-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return directory
    }

    /// Both logins open the browser themselves: the CLI prints a URL, launches the default
    /// browser and waits on its own loopback callback. So the CLI runs as a hidden child of
    /// claudex rather than in a Terminal window — the user sees the browser, which is where the
    /// sign-in actually happens, and not a console they have no reason to read.
    ///
    /// Output is captured so a failure can be reported in the panel instead of vanishing with
    /// the process.
    private static func launch(_ kind: ProviderKind, in directory: URL) throws -> LoginProcess {
        guard let executable = resolveExecutable(kind) else {
            Log.write("login: \(kind.executable) not found on \(searchPaths.joined(separator: ":"))")
            throw ClaudexError.unsupportedAccount(
                "\(kind.executable) is not installed where claudex can find it"
            )
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = kind.loginArguments

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in kind.configEnvironment(directory) { environment[key] = value }
        // A GUI process inherits a minimal PATH, and both CLIs shell out to helpers of their own.
        environment["PATH"] = ([executable.deletingLastPathComponent().path] + searchPaths)
            .joined(separator: ":")
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        // Claude Code ties its callback server's lifetime to stdin. An open pipe it never reads
        // from keeps the server up; `.nullDevice` reads EOF and tears it down mid-flow.
        process.standardInput = Pipe()

        do {
            try process.run()
            Log.write("login: spawned \(executable.path) \(kind.loginArguments.joined(separator: " ")) pid \(process.processIdentifier)")
        } catch {
            throw ClaudexError.unsupportedAccount("Could not start \(kind.executable): \(error.localizedDescription)")
        }
        return LoginProcess(process: process, output: output)
    }

    /// Holds the running login and everything it has said so far. The transcript is only read
    /// when the login fails, where it is the one explanation of why.
    final class LoginProcess {
        private let process: Process
        private let output: Pipe
        private let lock = NSLock()
        private var transcript = ""

        init(process: Process, output: Pipe) {
            self.process = process
            self.output = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let self else { return }
                self.lock.lock()
                self.transcript += String(decoding: data, as: UTF8.self)
                self.transcript = String(self.transcript.suffix(4000))
                self.lock.unlock()
                for line in String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .map({ $0.trimmingCharacters(in: .whitespaces) })
                where !line.isEmpty {
                    Log.write("cli: \(line.prefix(300))")
                }
            }
        }

        var isRunning: Bool { process.isRunning }

        var lastLine: String? {
            lock.lock()
            defer { lock.unlock() }
            return transcript
                .split(whereSeparator: \.isNewline)
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { String($0.trimmingCharacters(in: .whitespaces).suffix(200)) }
        }

        /// Called once the credential has been collected, and again on every failure path. The
        /// CLI would otherwise sit on its callback port until its own timeout.
        func stop() {
            output.fileHandleForReading.readabilityHandler = nil
            guard process.isRunning else { return }
            process.terminate()
            // A login that ignores SIGTERM still has a live refresh token in memory and a port
            // held open, so it does not get to outlive the window it was for.
            let running = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }

    /// The CLIs install to a handful of well-known places, none of which a GUI app's inherited
    /// PATH is guaranteed to include.
    private static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.claude/local",
        "\(NSHomeDirectory())/.codex/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    private static func resolveExecutable(_ kind: ProviderKind) -> URL? {
        let name = kind.executable
        let fromPath = (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        for directory in searchPaths + fromPath {
            let candidate = URL(fileURLWithPath: directory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Collecting the result

    private static func waitForCredentials(
        _ kind: ProviderKind,
        in directory: URL,
        servicesBefore: Set<String>,
        login: LoginProcess
    ) async throws -> Credentials {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let credentials = try? read(kind, in: directory, servicesBefore: servicesBefore) {
                // The CLI writes the file and then goes on to write the rest of its config, so
                // a moment's grace keeps a half-written file from being parsed as a whole one.
                try? await Task.sleep(for: .milliseconds(500))
                if let settled = try? read(kind, in: directory, servicesBefore: servicesBefore) {
                    return settled
                }
                return credentials
            }
            // The CLI exits as soon as the flow is cancelled or refused. Waiting out the full
            // timeout after that would leave the panel claiming a sign-in is still in progress.
            if !login.isRunning {
                // One more look: the credential may have landed between the last poll and exit.
                if let credentials = try? read(kind, in: directory, servicesBefore: servicesBefore) {
                    return credentials
                }
                Log.write("login: CLI exited before a credential appeared")
                throw ClaudexError.unsupportedAccount(
                    login.lastLine.map { "Sign-in did not finish: \($0)" } ?? "Sign-in did not finish"
                )
            }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        Log.write("login: timed out after \(Int(timeout)) seconds")
        throw ClaudexError.unsupportedAccount("Sign-in timed out after \(Int(timeout / 60)) minutes")
    }

    private static func read(
        _ kind: ProviderKind,
        in directory: URL,
        servicesBefore: Set<String>
    ) throws -> Credentials? {
        switch kind {
        case .codex:
            guard let data = try? Data(contentsOf: directory.appending(path: "auth.json")) else { return nil }
            return try CodexProvider.parse(data)

        case .claude:
            if let data = try? Data(contentsOf: directory.appending(path: ".credentials.json")),
               let credentials = try ClaudeProvider.parse(data) {
                return credentials
            }
            // Claude Code may keep the credential in the Keychain alone. The item it wrote is
            // whichever `Claude Code-credentials…` service was not there before this login.
            guard let service = try newService(since: servicesBefore),
                  let data = try ClaudeCLIKeychain.readRaw(service: service)
            else { return nil }
            return try ClaudeProvider.parse(data)
        }
    }

    private static func newService(since before: Set<String>) throws -> String? {
        try ClaudeCLIKeychain.credentialServices().subtracting(before).first
    }

    /// The throwaway directory and the item the login left behind both go, whether or not the
    /// sign-in succeeded. A live refresh token in a temp directory outlives the reason it exists.
    private static func clean(_ directory: URL, kind: ProviderKind, servicesBefore: Set<String>) {
        if kind == .claude, let service = (try? newService(since: servicesBefore)) ?? nil {
            try? ClaudeCLIKeychain.delete(service: service)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension ProviderKind {
    var executable: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    /// `--claudeai` picks the subscription flow over the console/API-key one, which is the only
    /// flow claudex can read usage for.
    var loginArguments: [String] {
        switch self {
        case .claude: return ["auth", "login", "--claudeai"]
        case .codex: return ["login"]
        }
    }

    /// Where the login is told to write. Claude Code 2.1.220 and later hash a second variable
    /// into their Keychain service name, so both have to point at the throwaway directory or the
    /// login lands on the account the CLI is already signed into.
    func configEnvironment(_ directory: URL) -> [String: String] {
        switch self {
        case .claude:
            return [
                "CLAUDE_CONFIG_DIR": directory.path,
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": directory.path,
            ]
        case .codex:
            return ["CODEX_HOME": directory.path]
        }
    }
}

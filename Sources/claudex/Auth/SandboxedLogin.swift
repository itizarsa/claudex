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
        let directory = try makeDirectory()
        // Claude Code derives its Keychain service name from the config directory, so the login
        // leaves an item behind under a name claudex cannot compute. Recording what existed
        // beforehand is how it is found afterwards, and how it gets cleaned up.
        let servicesBefore = (kind == .claude) ? ((try? ClaudeCLIKeychain.credentialServices()) ?? []) : []

        defer { clean(directory, kind: kind, servicesBefore: servicesBefore) }

        try launch(kind, in: directory)
        let credentials = try await waitForCredentials(kind, in: directory, servicesBefore: servicesBefore)

        // The gating lives in `fetchIdentity`: an API key or an account with no claude.ai
        // subscription is rejected there, before anything is written to the store.
        let identity = try await Providers.of(kind).fetchIdentity(credentials)

        if let existing = store.existing(matching: identity, kind: kind) {
            try store.storeCredentials(credentials, for: existing)
            return Result(account: existing, wasAlreadyKnown: true)
        }

        let label = CLIImport.suggestedLabel(for: identity, kind: kind, store: store)
        let account = try store.add(identity: identity, kind: kind, label: label, credentials: credentials)
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

    /// Both logins are interactive: they print a URL, open a browser and wait. A GUI app has no
    /// terminal to give them, so the command goes to Terminal.app and claudex watches the
    /// directory rather than the process. That also means the user can read what the CLI says
    /// when something goes wrong, which a captured pipe would swallow.
    private static func launch(_ kind: ProviderKind, in directory: URL) throws {
        let script = directory.appending(path: "login.sh")
        try Data(scriptBody(kind, directory: directory).utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: script.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", script.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClaudexError.unsupportedAccount("Could not open Terminal to run the sign-in")
        }
    }

    private static func scriptBody(_ kind: ProviderKind, directory: URL) -> String {
        let (variable, command, executable) = switch kind {
        case .claude: ("CLAUDE_CONFIG_DIR", "claude auth login --claudeai", "claude")
        case .codex: ("CODEX_HOME", "codex login", "codex")
        }

        // Terminal starts a login shell, but not every installation puts the CLI on the PATH a
        // non-interactive script inherits, so the usual locations are added rather than left to
        // chance.
        return """
        #!/bin/sh
        export PATH="$HOME/.local/bin:$HOME/.claude/local:$HOME/.codex/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        export \(variable)="\(directory.path)"
        echo "Signing in to a separate \(kind.displayName) account."
        echo "Your current account is untouched — this runs against a throwaway directory."
        echo
        if ! command -v \(executable) >/dev/null 2>&1; then
            echo "\(executable) is not on the PATH. Install it, or run this by hand:"
            echo "  \(variable)=\(directory.path) \(command)"
            echo
            echo "Press return to close."
            read _
            exit 1
        fi
        \(command)
        echo
        echo "Done. Claudex is picking this up; you can close this window."
        """
    }

    // MARK: - Collecting the result

    private static func waitForCredentials(
        _ kind: ProviderKind,
        in directory: URL,
        servicesBefore: Set<String>
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
            try await Task.sleep(for: .seconds(pollInterval))
        }
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

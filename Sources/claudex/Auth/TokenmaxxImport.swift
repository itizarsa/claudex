import Foundation
import SQLite3

/// Adopt accounts from tokenmaxx, which solves the same problem by proxying requests rather
/// than swapping CLI credentials. Anyone moving across has their accounts there already, and
/// signing each one in again by hand is the worst part of switching tools.
///
/// Read-only in both stores it touches: tokenmaxx keeps its metadata in a SQLite database under
/// `~/.tokenmaxx` and its tokens in Keychain items under its own service, and this reads a copy
/// of each into claudex's vault. Nothing is written back, so both tools keep working.
enum TokenmaxxImport {
    private static let keychainService = "com.rubriclabs.tokmax"
    /// tokenmaxx splits oversized values the same way claudex does, under its own marker.
    private static let manifestPrefix = "tokmax-chunks:"

    static var databaseURL: URL {
        let root = ProcessInfo.processInfo.environment["TOKENMAXX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".tokenmaxx")
        return root.appending(path: "state.sqlite")
    }

    struct Candidate {
        let label: String
        let kind: ProviderKind
        let credentials: Credentials
        let email: String?
        let plan: String?
        let remoteID: String?
    }

    struct Outcome {
        let imported: [Account]
        let skipped: [(label: String, reason: String)]
    }

    // MARK: - Reading tokenmaxx

    /// The stored account row. Only the fields claudex needs; tokenmaxx carries more.
    private struct StoredAccount: Decodable {
        let auth: String?
        let enabled: Bool?
        let externalAccountId: String?
        let identity: String?
        let label: String?
        let plan: String?
        let provider: String
        let secretReference: String?
    }

    private struct StoredClaudeCredential: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double
        let refreshTokenExpiresAt: Double?
        let subscriptionType: String?
        let rateLimitTier: String?
        /// tokenmaxx accepts either shape from the CLI and stores whichever it got.
        let scopes: Scopes?

        enum Scopes: Decodable {
            case list([String])
            case joined(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let list = try? container.decode([String].self) {
                    self = .list(list)
                } else {
                    self = .joined(try container.decode(String.self))
                }
            }

            var values: [String] {
                switch self {
                case .list(let list): return list
                case .joined(let joined): return joined.split(separator: " ").map(String.init)
                }
            }
        }
    }

    private struct StoredCodexCredential: Decodable {
        struct Tokens: Decodable {
            let access_token: String
            let id_token: String
            let refresh_token: String
            let account_id: String?
        }
        let tokens: Tokens
        let last_refresh: String?
    }

    static func candidates() throws -> [Candidate] {
        let rows = try readAccountRows()
        var found: [Candidate] = []

        for row in rows {
            guard row.enabled != false, let reference = row.secretReference else { continue }
            // claudex tracks subscription usage windows; an API key has none to show.
            guard row.auth != "apiKey" else { continue }

            let kind: ProviderKind
            switch row.provider {
            case "anthropic": kind = .claude
            case "openai": kind = .codex
            default: continue
            }

            guard let secret = try KeychainItem.read(
                service: keychainService,
                account: reference,
                manifestPrefix: manifestPrefix
            ) else { continue }

            let data = Data(secret.utf8)
            let credentials: Credentials
            switch kind {
            case .claude:
                let stored = try JSONDecoder().decode(StoredClaudeCredential.self, from: data)
                credentials = .claude(ClaudeCredentials(
                    accessToken: stored.accessToken,
                    refreshToken: stored.refreshToken,
                    expiresAt: Int64(stored.expiresAt),
                    refreshTokenExpiresAt: stored.refreshTokenExpiresAt.map(Int64.init),
                    scopes: stored.scopes?.values ?? [],
                    subscriptionType: stored.subscriptionType,
                    rateLimitTier: stored.rateLimitTier
                ))
            case .codex:
                let stored = try JSONDecoder().decode(StoredCodexCredential.self, from: data)
                credentials = .codex(CodexCredentials(
                    idToken: stored.tokens.id_token,
                    accessToken: stored.tokens.access_token,
                    refreshToken: stored.tokens.refresh_token,
                    accountID: stored.tokens.account_id ?? "",
                    lastRefresh: stored.last_refresh.flatMap(ISO8601DateFormatter().date(from:))
                ))
            }

            found.append(Candidate(
                label: row.label ?? row.identity ?? reference,
                kind: kind,
                credentials: credentials,
                email: row.identity,
                plan: row.plan,
                remoteID: row.externalAccountId
            ))
        }
        return found
    }

    /// One statement, read-only, no write lock: tokenmaxx may be running.
    private static func readAccountRows() throws -> [StoredAccount] {
        let path = databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ClaudexError.unsupportedAccount("No tokenmaxx database at \(path)")
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw ClaudexError.unsupportedAccount("Could not open \(path)")
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT payload FROM accounts", -1, &statement, nil) == SQLITE_OK else {
            throw ClaudexError.unsupportedAccount("tokenmaxx database has no accounts table")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [StoredAccount] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let payload = Data(String(cString: text).utf8)
            guard let decoded = try? JSONDecoder().decode(StoredAccount.self, from: payload) else { continue }
            rows.append(decoded)
        }
        return rows
    }

    // MARK: - Importing

    /// Imported accounts are left inactive. Which account a CLI is signed into is a separate
    /// decision from which accounts claudex knows about, and importing should not switch anyone.
    @MainActor
    static func importAll(into store: AccountStore) async -> Outcome {
        let found: [Candidate]
        do {
            found = try candidates()
        } catch {
            return Outcome(imported: [], skipped: [("tokenmaxx", message(error))])
        }

        var imported: [Account] = []
        var skipped: [(label: String, reason: String)] = []

        for candidate in found {
            do {
                let identity = try await identity(for: candidate)
                if let existing = store.existing(matching: identity, kind: candidate.kind) {
                    skipped.append((candidate.label, "already known as \(existing.label)"))
                    continue
                }
                let account = try store.add(
                    identity: identity,
                    kind: candidate.kind,
                    label: candidate.label,
                    credentials: candidate.credentials
                )
                imported.append(account)
            } catch {
                skipped.append((candidate.label, message(error)))
            }
        }
        return Outcome(imported: imported, skipped: skipped)
    }

    /// The provider is asked first, so the imported account carries the same identity claudex
    /// would have derived from a CLI import. tokenmaxx's own record is the fallback for a token
    /// too stale to introduce itself, which is worth importing anyway — it can still refresh.
    private static func identity(for candidate: Candidate) async throws -> Identity {
        do {
            return try await Providers.of(candidate.kind).fetchIdentity(candidate.credentials)
        } catch {
            guard let email = candidate.email, let remoteID = candidate.remoteID else { throw error }
            return Identity(
                email: email,
                displayName: nil,
                plan: candidate.plan ?? "unknown",
                organization: nil,
                remoteID: remoteID
            )
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? ClaudexError)?.errorDescription ?? error.localizedDescription
    }
}

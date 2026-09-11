import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // Our own container.
    static var support: URL {
        home.appending(path: "Library/Application Support/claudex", directoryHint: .isDirectory)
    }
    static var accountsFile: URL { support.appending(path: "accounts.json") }
    static var settingsFile: URL { support.appending(path: "settings.json") }
    static var snapshotCache: URL { support.appending(path: "snapshots.json") }
    static var vaultFile: URL { support.appending(path: "vault.json") }

    // CLI state we read, and (for the active account only) mirror refreshed tokens back to.
    static var claudeCredentials: URL { home.appending(path: ".claude/.credentials.json") }
    static var claudeConfig: URL { home.appending(path: ".claude.json") }
    static var codexAuth: URL { home.appending(path: ".codex/auth.json") }

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
}

enum AtomicFile {
    /// Write via temp file plus rename, so a crash mid-write can never leave the CLI with a
    /// truncated credentials file. Preserves the original POSIX permissions when replacing.
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let existingMode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        let temp = directory.appending(path: ".claudex-tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: existingMode ?? NSNumber(value: 0o600)],
            ofItemAtPath: temp.path
        )
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Keep one rollback copy next to the file we are about to replace.
    static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let destination = url.appendingPathExtension("claudex-backup")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
    }
}

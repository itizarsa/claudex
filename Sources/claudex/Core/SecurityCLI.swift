import Foundation

/// Keychain access by way of `/usr/bin/security` rather than the Security framework.
///
/// `SecItemCopyMatching` from a locally built app never returns: an ad-hoc signature changes on
/// every rebuild, macOS treats each build as a new application, and the call parks in `securityd`
/// waiting on an authorisation prompt that a background poll cannot answer. `/usr/bin/security`
/// is Apple-signed with a stable identity, so the same operations complete without a prompt.
enum SecurityCLI {
    /// `security` itself has been observed to hang indefinitely on some macOS builds, so every
    /// invocation is bounded. A hung Keychain call must degrade to an error, never to a stall.
    static let timeout: TimeInterval = 8

    /// `security`'s exit code for "no such item", which is an expected answer rather than a fault.
    static let itemNotFound: Int32 = 44

    struct Output {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Secrets go in on stdin wherever the caller can arrange it: an argument vector is visible
    /// to any `ps` on the machine for the lifetime of the process.
    static func run(_ arguments: [String], input: String? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outPipe = Pipe()
        let errorPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errorPipe
        process.standardInput = inPipe

        try process.run()

        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        // Drain both pipes on their own queues: a child that fills a pipe buffer while the parent
        // waits on exit deadlocks, and `security` is chatty on stderr.
        var outData = Data()
        var errorData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "io.claudex.security", attributes: .concurrent)
        queue.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group: group) { errorData = errorPipe.fileHandleForReading.readDataToEndOfFile() }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
            throw ClaudexError.unsupportedAccount("Keychain timed out after \(Int(timeout))s")
        }
        process.waitUntilExit()

        return Output(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}

/// One generic-password item per account. Values are stored base64-encoded, which keeps them
/// inside a character set `security`'s interactive parser will not mangle and lets the secret
/// travel on stdin instead of in the argument vector.
enum KeychainItem {
    /// Keychain truncates large generic-password payloads, so anything longer is split and
    /// reassembled from a manifest item. Observed by other tools at roughly 2 KB.
    private static let chunkLength = 2_048
    private static let maximumChunks = 64
    static let manifestPrefix = "claudex-chunks:"

    /// `manifestPrefix` is a parameter because the same base64-plus-chunks layout is used by
    /// other tools under their own marker, and importing from one means reading its items.
    static func read(service: String, account: String, manifestPrefix: String = manifestPrefix) throws -> String? {
        guard let stored = try readRawBase64(service: service, account: account) else { return nil }
        guard let decoded = decodeBase64(stored) else {
            throw ClaudexError.decoding("Keychain item \(account) is not base64")
        }
        guard decoded.hasPrefix(manifestPrefix) else { return decoded }

        let count = Int(decoded.dropFirst(manifestPrefix.count)) ?? 0
        guard count > 0, count <= maximumChunks else {
            throw ClaudexError.decoding("Keychain item \(account) declares an invalid chunk count")
        }
        var joined = ""
        for index in 0..<count {
            guard let chunk = try readRawBase64(service: service, account: "\(account):\(index)") else {
                throw ClaudexError.decoding("Keychain item \(account) is missing chunk \(index)")
            }
            joined += chunk
        }
        guard let value = decodeBase64(joined) else {
            throw ClaudexError.decoding("Keychain item \(account) reassembled to invalid base64")
        }
        return value
    }

    static func write(service: String, account: String, value: String) throws {
        let encoded = Data(value.utf8).base64EncodedString()
        if encoded.count <= chunkLength {
            try writeRawBase64(service: service, account: account, base64: encoded)
            try deleteChunks(service: service, account: account, from: 0)
            return
        }

        let chunks = stride(from: 0, to: encoded.count, by: chunkLength).map { offset -> String in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: chunkLength, limitedBy: encoded.endIndex) ?? encoded.endIndex
            return String(encoded[start..<end])
        }
        guard chunks.count <= maximumChunks else {
            throw ClaudexError.unsupportedAccount("Credential exceeds \(maximumChunks) Keychain chunks")
        }
        for (index, chunk) in chunks.enumerated() {
            try writeRawBase64(service: service, account: "\(account):\(index)", base64: chunk)
        }
        let manifest = Data("\(manifestPrefix)\(chunks.count)".utf8).base64EncodedString()
        try writeRawBase64(service: service, account: account, base64: manifest)
        try deleteChunks(service: service, account: account, from: chunks.count)
    }

    @discardableResult
    static func delete(service: String, account: String) throws -> Bool {
        let output = try SecurityCLI.run(["delete-generic-password", "-s", service, "-a", account])
        if output.exitCode == SecurityCLI.itemNotFound { return false }
        guard output.exitCode == 0 else { throw failure("delete", output) }
        try deleteChunks(service: service, account: account, from: 0)
        return true
    }

    private static func readRawBase64(service: String, account: String) throws -> String? {
        let output = try SecurityCLI.run(["find-generic-password", "-s", service, "-a", account, "-w"])
        if output.exitCode == SecurityCLI.itemNotFound { return nil }
        guard output.exitCode == 0 else { throw failure("read", output) }
        return output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeRawBase64(service: String, account: String, base64: String) throws {
        // `-i` reads the command from stdin, keeping the secret out of the argument vector.
        let command = "add-generic-password -U -s \(service) -a \(account) -w \(base64)\n"
        let output = try SecurityCLI.run(["-i"], input: command)
        guard output.exitCode == 0 else { throw failure("write", output) }
    }

    private static func deleteChunks(service: String, account: String, from first: Int) throws {
        for index in first..<maximumChunks {
            let output = try SecurityCLI.run([
                "delete-generic-password", "-s", service, "-a", "\(account):\(index)",
            ])
            if output.exitCode != 0 { return }
        }
    }

    private static func decodeBase64(_ encoded: String) -> String? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Keychain errors carry the secret in neither stream, but `security` echoes arguments, so
    /// the message is trimmed to its first line rather than passed through whole.
    private static func failure(_ operation: String, _ output: SecurityCLI.Output) -> ClaudexError {
        let detail = output.standardError
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "exit \(output.exitCode)"
        return ClaudexError.unsupportedAccount("Keychain \(operation) failed: \(detail)")
    }
}

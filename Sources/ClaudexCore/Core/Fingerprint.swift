import CryptoKit
import Foundation

enum Fingerprint {
    /// Short, non-reversible digest. Used to compare credentials for identity without
    /// logging or persisting the secret itself.
    static func of(_ secret: String) -> String {
        let digest = SHA256.hash(data: Data(secret.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

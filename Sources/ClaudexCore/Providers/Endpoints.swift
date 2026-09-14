import Foundation

/// Every remote address and public client id lives here. These are the parts most likely to
/// change underneath the app, so they are kept in one place rather than inlined at call sites.
enum Endpoints {
    enum Claude {
        /// Where routed inference traffic goes. Subscription requests use the same host the
        /// CLI would have called directly, so the proxy changes the credential and nothing else.
        static let inference = URL(string: "https://api.anthropic.com")!
        static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        static let profile = URL(string: "https://api.anthropic.com/api/oauth/profile")!
        /// Primary token endpoint, with the older console host as a fallback.
        static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
        static let tokenFallback = URL(string: "https://console.anthropic.com/v1/oauth/token")!
        static let authorize = URL(string: "https://claude.ai/oauth/authorize")!
        static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        static let betaHeader = "oauth-2025-04-20"
        static let scopes = [
            "user:inference",
            "user:profile",
            "user:sessions:claude_code",
            "user:file_upload",
            "user:mcp_servers",
        ]
    }

    enum Codex {
        /// The ChatGPT-backed Codex endpoint, not the public OpenAI API: a subscription token
        /// is only accepted here.
        static let inference = URL(string: "https://chatgpt.com/backend-api/codex")!
        static let usage = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        static let token = URL(string: "https://auth.openai.com/oauth/token")!
        static let authorize = URL(string: "https://auth.openai.com/oauth/authorize")!
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let redirect = "http://localhost:1455/auth/callback"
        static let scopes = ["openid", "profile", "email", "offline_access"]
    }

    static let userAgent = "claudex/0.1 (macOS)"
}

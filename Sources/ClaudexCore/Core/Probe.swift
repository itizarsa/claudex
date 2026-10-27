import Foundation

public enum Probe {
    /// Prints what claudex parsed from CLIProxyAPI.
    public static func list() async {
        do {
            let accounts = try await CLIProxy.status(fetch: true)
            guard !accounts.isEmpty else {
                print("no accounts; run cliproxyapi -claude-login")
                return
            }
            for account in accounts {
                let marker = account.isActive ? "*" : " "
                let fiveHour = account.snapshot?.fiveHour.percentText ?? "—"
                let weekly = account.snapshot?.weekly.percentText ?? "—"
                print("\(marker) \(account.email)  5h \(fiveHour)  week \(weekly)  [\(account.plan)] \(account.health)")
            }
        } catch {
            print("FAILED: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }
    }
}

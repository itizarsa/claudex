import Foundation

public enum Probe {
    /// Prints what claudex parsed from `tokenmaxx status`.
    public static func list() async {
        do {
            let accounts = try await Tokenmaxx.status()
            guard !accounts.isEmpty else {
                print("no accounts; run tokenmaxx login claude or tokenmaxx login codex")
                return
            }
            for account in accounts {
                let marker = account.isActive ? "*" : " "
                let fiveHour = account.snapshot?.fiveHour.percentText ?? "—"
                let weekly = account.snapshot?.weekly.percentText ?? "—"
                print("\(marker) \(account.provider.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(account.email)  5h \(fiveHour)  week \(weekly)  [\(account.plan)] \(account.health)")
            }
        } catch {
            print("FAILED: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }
    }
}

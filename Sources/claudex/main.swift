import ClaudexCore
import Foundation

/// Small headless surface for setup and diagnostics. Without a flag the app launches as a
/// menu bar item.
let arguments = Set(CommandLine.arguments.dropFirst())

// Laying out a view needs the real main thread, which `dispatchMain()` below gives away.
if let index = CommandLine.arguments.firstIndex(of: "--panelshot"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { Probe.renderPanel(path: CommandLine.arguments[index + 1]) }
    exit(0)
}

if !arguments.isEmpty {
    // The work runs on the main actor, so the main thread must hand itself to the dispatch
    // main queue rather than block waiting on the result, which would deadlock.
    Task { @MainActor in
        let credentialStore = KeychainCredentialStore()
        let providers = ProviderRegistry.live()
        let store = AccountStore(credentialStore: credentialStore)
        let selector = AccountSelector(store: store)
        let login = SandboxedLogin(store: store, providers: providers, selector: selector)
        let reader = UsageReader(store: store, providers: providers)

        if arguments.contains("--vault") { Probe.vaultSelfTest(store: credentialStore) }
        if arguments.contains("--probe") { await Probe.run(providers: providers) }
        if let index = CommandLine.arguments.firstIndex(of: "--switch"),
           index + 1 < CommandLine.arguments.count {
            await Probe.switchTo(CommandLine.arguments[index + 1], store: store, selector: selector)
        }
        if arguments.contains("--poll") { await Probe.pollOnce(store: store, reader: reader) }
        if arguments.contains("--rotate") { await Probe.rotationPlan(store: store, reader: reader) }
        if let index = CommandLine.arguments.firstIndex(of: "--login"),
           index + 1 < CommandLine.arguments.count {
            await Probe.login(CommandLine.arguments[index + 1], login: login)
        }
        if arguments.contains("--list") { Probe.list(store: store) }
        if let index = CommandLine.arguments.firstIndex(of: "--appicon"),
           index + 1 < CommandLine.arguments.count {
            Probe.renderAppIcon(path: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--icon"),
           index + 4 < CommandLine.arguments.count {
            let a = CommandLine.arguments
            Probe.renderIcon(
                path: a[index + 1],
                alias: a[index + 2],
                percent: a[index + 3],
                elapsed: a[index + 4]
            )
        }
        exit(0)
    }
    dispatchMain()
}

ClaudexApp.main()

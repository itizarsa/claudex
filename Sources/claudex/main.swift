import Foundation

/// Small headless surface for setup and diagnostics. Without a flag the app launches as a
/// menu bar item.
let arguments = Set(CommandLine.arguments.dropFirst())

if !arguments.isEmpty {
    // The work runs on the main actor, so the main thread must hand itself to the dispatch
    // main queue rather than block waiting on the result, which would deadlock.
    Task {
        if arguments.contains("--vault") { Probe.vaultSelfTest() }
        if arguments.contains("--probe") { await Probe.run() }
        if arguments.contains("--import") { await Probe.importCurrent() }
        if arguments.contains("--poll") { await Probe.pollOnce() }
        if arguments.contains("--list") { await Probe.list() }
        exit(0)
    }
    dispatchMain()
}

ClaudexApp.main()

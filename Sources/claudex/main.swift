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
        if let index = CommandLine.arguments.firstIndex(of: "--switch"),
           index + 1 < CommandLine.arguments.count {
            await Probe.switchTo(CommandLine.arguments[index + 1])
        }
        if arguments.contains("--poll") { await Probe.pollOnce() }
        if arguments.contains("--rotate") { await Probe.rotationPlan() }
        if let index = CommandLine.arguments.firstIndex(of: "--login"),
           index + 1 < CommandLine.arguments.count {
            await Probe.login(CommandLine.arguments[index + 1])
        }
        if arguments.contains("--list") { await Probe.list() }
        if let index = CommandLine.arguments.firstIndex(of: "--appicon"),
           index + 1 < CommandLine.arguments.count {
            await Probe.renderAppIcon(path: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--icon"),
           index + 4 < CommandLine.arguments.count {
            let a = CommandLine.arguments
            await Probe.renderIcon(
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

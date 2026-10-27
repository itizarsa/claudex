import AppKit

/// Reopens the app once an upgrade replaces its bundle. Homebrew runs cask steps sandboxed, with
/// no Apple Events or LaunchServices, so the cask can't quit and reopen it; the app has to notice
/// on its own. The build number rises with every commit, so a different one on disk means the
/// running copy is stale.
@MainActor
final class UpdateRelauncher {
    private let bundleURL = Bundle.main.bundleURL
    private let runningBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    private var sources: [DispatchSourceFileSystemObject] = []

    /// Watches the bundle and the folder holding it. Homebrew 7 keeps the bundle and swaps its
    /// `Contents`, a write to the bundle; a fresh install replaces the bundle, a write to the
    /// folder. Nothing runs until one of them changes.
    func start() {
        guard runningBuild != nil else { return }
        for url in [bundleURL, bundleURL.deletingLastPathComponent()] {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.check() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func check() {
        // Mid-upgrade the bundle is briefly missing; the next write brings the new one.
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let build = info["CFBundleVersion"] as? String,
              build != runningBuild
        else { return }

        sources.forEach { $0.cancel() }
        // A second copy can't open while this one runs, so a detached shell waits for this
        // process to exit and then opens the new bundle.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            bundleURL.path,
        ]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}

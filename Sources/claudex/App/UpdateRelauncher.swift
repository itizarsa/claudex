import AppKit

/// Reopens the app once an upgrade replaces its bundle. Homebrew runs cask steps sandboxed, with
/// no Apple Events or LaunchServices, so the cask can't quit and reopen it; the app has to notice
/// on its own. The build number rises with every commit, so a different one on disk means the
/// running copy is stale.
@MainActor
final class UpdateRelauncher {
    private let bundleURL = Bundle.main.bundleURL
    private let runningBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    private var source: DispatchSourceFileSystemObject?

    /// Watches the folder holding the bundle. An upgrade removes the old bundle and moves the new
    /// one in, and both are writes to that folder, so nothing runs until something there changes.
    func start() {
        guard runningBuild != nil else { return }
        let fd = open(bundleURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func check() {
        // Mid-upgrade the bundle is briefly missing; the next write brings the new one.
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let build = info["CFBundleVersion"] as? String,
              build != runningBuild
        else { return }

        source?.cancel()
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

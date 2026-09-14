import AppKit
import ClaudexCore
import SwiftUI

/// The drawing half of the headless surface. `make icon` runs the app to produce its own icon,
/// and `--panelshot` draws the real panel, so both live with the views they render rather than
/// with the diagnostics in ClaudexCore.
extension Probe {
    /// Writes the menu-bar image to a PNG at 2x so its geometry can be measured against a
    /// screenshot of the app it is modelled on. Each argument takes a comma-separated list, one
    /// element per ring, so the grouped layout can be checked too. Diagnostics only; nothing in
    /// the app calls it.
    /// Writes the app icon at 1024 so `make icon` can hand it to `iconutil`. Drawn by the same
    /// binary that draws the ring, so the two cannot drift apart.
    @MainActor
    static func renderAppIcon(path: String) {
        do {
            try AppIcon.write(to: path)
            print("wrote \(path)")
        } catch {
            print("app icon failed: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    /// Renders the panel itself to a PNG, so its layout can be looked at without opening it.
    /// Draws the real view against the real store, which is the only way the image and the app
    /// cannot disagree.
    @MainActor
    static func renderPanel(path: String) {
        let providers = ProviderRegistry.live()
        let store = AccountStore(credentialStore: KeychainCredentialStore())
        let selector = AccountSelector(store: store)
        let login = SandboxedLogin(store: store, providers: providers, selector: selector)
        let reader = UsageReader(store: store, providers: providers)
        let notifier = Notifier()
        let rotator = Rotator(store: store, notifier: notifier, selector: selector)
        let engine = UsageEngine(
            store: store,
            activity: LocalUsageActivity(),
            reader: reader,
            notifier: notifier,
            rotator: rotator
        )
        // Screenshot rendering must not reach the real CLI config files, so the installer is
        // pointed at a throwaway directory that nothing ever reads back.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "claudex-probe-\(UUID().uuidString)")
        let routing = RoutingController(
            proxy: LoopbackAccountProxy(routing: StaticAccountRouting([:])),
            installer: NativeCLIRoutingInstaller(
                claudeSettings: scratch.appending(path: "settings.json"),
                codexConfig: scratch.appending(path: "config.toml"),
                backups: scratch.appending(path: "routing.json")
            )
        )
        let state = PanelState(store: store, engine: engine, selector: selector, login: login, routing: routing)
        // AppKit needs its application object before a view can be laid out, and the panel is
        // laid out here on the real main thread rather than on the main queue: under
        // `dispatchMain()` the two are not the same thread.
        _ = NSApplication.shared
        let view = NSHostingView(rootView: UsagePopover(state: state))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()

        // A popover draws over a vibrant background; on a transparent one the tints read wrong.
        let backing = NSView(frame: view.frame)
        backing.wantsLayer = true
        backing.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        backing.appearance = NSAppearance(named: .darkAqua)
        backing.addSubview(view)

        guard let rep = backing.bitmapImageRepForCachingDisplay(in: backing.bounds) else { return }
        backing.cacheDisplay(in: backing.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) at \(Int(rep.size.width))x\(Int(rep.size.height))")
    }

    @MainActor
    static func renderIcon(path: String, alias: String, percent: String, elapsed: String) {
        let aliases = alias.split(separator: ",").map(String.init)
        let percents = percent.split(separator: ",").map { Double($0) }
        let elapseds = elapsed.split(separator: ",").map { Double($0) ?? 0 }

        let entries = aliases.enumerated().map { index, alias -> MenuBarIcon.Entry in
            let spent = index < elapseds.count ? elapseds[index] : 0
            let window = UsageWindow(
                percent: index < percents.count ? percents[index] : nil,
                resetsAt: Date().addingTimeInterval(5 * 3600 * (1 - spent)),
                windowSeconds: 5 * 3600
            )
            return MenuBarIcon.Entry(alias: alias, fiveHour: window)
        }
        let image = MenuBarIcon.rings(entries)

        let pixelWidth = Int(image.size.width.rounded()) * 2
        let pixelHeight = Int(image.size.height.rounded()) * 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = image.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) at \(pixelWidth)x\(pixelHeight)")
    }
}

import AppKit
import ClaudexCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let state = PanelState(engine: UsageEngine())
    /// One status item carrying every provider's ring. Each provider has its own active
    /// account, so each needs its own ring; one item keeps them one click target.
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp])

        let controller = NSHostingController(rootView: UsagePopover(state: state))
        controller.sizingOptions = [.preferredContentSize]
        // The panel is designed dark-only. Pinning the appearance keeps the tint over the
        // popover's material predictable instead of following the system light theme.
        controller.view.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        observeStatusIcon()
        state.engine.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // NSPopover centres its arrow on this rect, keeping the panel centred beneath
            // the menu-bar item regardless of panel width.
            // A status item click does not activate an accessory app, and an inactive app's
            // popover window cannot become key — which leaves every control in it inert: the
            // clicks arrive and SwiftUI drops them. Activating first is what makes the buttons
            // work at all.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await state.engine.load() }
            // The item stays lit for as long as the panel is open, which is what tells you
            // which icon the panel belongs to.
            button.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    private func observeStatusIcon() {
        withObservationTracking {
            updateStatusIcon()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.observeStatusIcon()
            }
        }
    }

    /// Redraws one ring per provider that has an account, each from that provider's active
    /// account, and resizes the item to suit. Before any account exists a single empty ring is
    /// drawn, or the app would have nothing to click.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let statusEntries = state.statusEntries
        let entries = statusEntries.map { entry -> MenuBarIcon.Entry in
            return MenuBarIcon.Entry(
                alias: entry.account?.badge ?? "-",
                fiveHour: entry.account?.snapshot?.fiveHour ?? .unknown
            )
        }

        let drawn = entries.isEmpty ? [MenuBarIcon.Entry(alias: "-", fiveHour: .unknown)] : entries
        statusItem.length = MenuBarIcon.width(forRings: drawn.count)
        button.image = MenuBarIcon.rings(drawn)
        button.imagePosition = .imageOnly
        button.toolTip = statusEntries.isEmpty
            ? "Claudex usage"
            : statusEntries.map { entry in
                "\(entry.kind.displayName): \(entry.account?.email ?? "no account")"
            }.joined(separator: "\n")
    }
}

struct ClaudexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        SwiftUI.Settings {
            EmptyView()
        }
    }
}

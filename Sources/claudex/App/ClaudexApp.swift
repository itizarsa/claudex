import AppKit
import ClaudexCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let state = PanelState(engine: UsageEngine())
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

    /// Redraws the ring from the active account. Before any account exists an empty ring is
    /// drawn, or the app would have nothing to click.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let account = state.accounts.first
        let entry = MenuBarIcon.Entry(
            alias: account?.badge ?? "-",
            fiveHour: account?.snapshot?.fiveHour ?? .unknown
        )
        statusItem.length = MenuBarIcon.width(forRings: 1)
        button.image = MenuBarIcon.rings([entry])
        button.imagePosition = .imageOnly
        button.toolTip = account.map { "Claude: \($0.email)" } ?? "Claudex usage"
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

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store: AccountStore
    private let engine: UsageEngine
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    override init() {
        let store = AccountStore()
        self.store = store
        self.engine = UsageEngine(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.toolTip = "Claudex usage"
        // variableLength pads the button ~10 pt wider than the image, and the click highlight
        // fills all of it, so a round ring ends up inside a wide pill. Matching the item to the
        // icon's square makes the highlight read as a circle, like every other status item.
        statusItem.length = NSStatusBar.system.thickness + 2

        let controller = NSHostingController(rootView: UsagePopover(store: store, engine: engine))
        controller.sizingOptions = [.preferredContentSize]
        // The panel is designed dark-only. Pinning the appearance keeps the tint over the
        // popover's material predictable instead of following the system light theme.
        controller.view.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        observeStatusIcon()
        engine.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // NSPopover centres its arrow on this rect, keeping the panel centred beneath
            // the menu-bar item regardless of panel width.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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

    private func updateStatusIcon() {
        let account = store.activeAccount(for: store.settings.menuBarProvider)
            ?? store.accounts.first { store.state($0.id).snapshot != nil }
        let snapshot = account.flatMap { store.state($0.id).snapshot }

        statusItem.button?.image = MenuBarIcon.ring(
            alias: account?.badge ?? "-",
            fiveHour: snapshot?.fiveHour ?? .unknown,
            weekly: snapshot?.weekly ?? .unknown
        )
        statusItem.button?.imagePosition = .imageOnly
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

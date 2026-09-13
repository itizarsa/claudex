import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store: AccountStore
    private let engine: UsageEngine
    /// One status item carrying every provider's ring. Active is a per-provider fact — signing a
    /// Claude account in does not change which Codex account is live — so each provider needs
    /// its own ring; but one item per provider would be two click targets opening the same
    /// panel and two things to drag into position, so the rings share an item.
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    override init() {
        let store = AccountStore()
        self.store = store
        self.engine = UsageEngine(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp])

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

    /// Redraws one ring per provider that has an account, each from that provider's own active
    /// account, and resizes the item to suit. Before any account exists a single empty ring is
    /// drawn, or the app would have nothing to click.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let populated = ProviderKind.allCases.filter { !store.accounts(for: $0).isEmpty }
        let entries = populated.map { kind -> MenuBarIcon.Entry in
            let account = store.activeAccount(for: kind) ?? store.accounts(for: kind).first
            let snapshot = account.flatMap { store.state($0.id).snapshot }
            return MenuBarIcon.Entry(
                alias: account?.badge ?? "-",
                fiveHour: snapshot?.fiveHour ?? .unknown
            )
        }

        let drawn = entries.isEmpty ? [MenuBarIcon.Entry(alias: "-", fiveHour: .unknown)] : entries
        statusItem.length = MenuBarIcon.width(forRings: drawn.count)
        button.image = MenuBarIcon.rings(drawn)
        button.imagePosition = .imageOnly
        button.toolTip = populated.isEmpty
            ? "Claudex usage"
            : populated.map { kind in
                let account = store.activeAccount(for: kind) ?? store.accounts(for: kind).first
                return "\(kind.displayName): \(account?.label ?? "no account")"
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

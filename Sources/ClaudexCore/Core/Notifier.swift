import Foundation
import UserNotifications

/// User-facing notifications, and nothing else. Every switch and every exhausted provider is
/// announced here; the app never kills a running session, so the notification is the only
/// signal that the account under the next `claude` or `codex` run has changed.
@MainActor
final class Notifier {
    private var authorized = false
    private var requested = false

    /// `UNUserNotificationCenter.current()` raises when the process has no application bundle,
    /// which is exactly what `--poll` and `--switch` run as. Gating on the bundle keeps the
    /// headless paths usable rather than making them crash on their first notification.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asked for once at launch, so the prompt lands while the user is looking at the app
    /// rather than at the moment of the first switch.
    func prepare() {
        guard isAvailable, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func post(title: String, body: String) {
        guard isAvailable, authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

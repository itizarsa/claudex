import Foundation
import ServiceManagement

/// Login-item registration through `SMAppService`, which registers the bundle itself and needs
/// no helper target or `launchd` plist of our own.
///
/// The registration is keyed to the bundle's location, so a bundle moved after registering is
/// reported as `.notFound`; `make install` putting it in `/Applications` is what keeps that
/// stable. Unavailable when running from the bare executable, where there is no bundle to
/// register at all.
enum LaunchAtLogin {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        guard isAvailable else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

import ClaudexCore
import ServiceManagement
import SwiftUI

/// The settings face of the popover. It replaces the account list rather than opening a window,
/// because a separate window for one toggle is a second thing to find and close.
struct SettingsPanel: View {
    @Bindable var state: PanelState

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            group("Startup") {
                SettingRow(
                    title: "Launch at login",
                    caption: LaunchAtLogin.isAvailable
                        ? "Registers the app itself; moving the bundle clears the registration."
                        : "Available once the app runs from a bundle. Use make install."
                ) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(!LaunchAtLogin.isAvailable)
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                }
            }

            if let notice {
                Text(notice)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("SETTINGS")
                .font(Theme.sectionHeader)
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            IconButton(systemName: "chevron.left", help: "Back to accounts", action: state.closeSettings)
        }
        .padding(.leading, 2)
    }

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.pill)
                .tracking(0.5)
                .foregroundStyle(Theme.tertiaryText)
            content()
        }
        .padding(.horizontal, Theme.cardPaddingH)
        .padding(.vertical, Theme.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: Theme.cardStrokeWidth)
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            notice = nil
        } catch {
            // Report the refusal and put the switch back where the system actually is, rather
            // than leaving a toggle claiming something that did not happen.
            notice = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

/// A labelled line with its control on the right and an explanation under it.
struct SettingRow<Control: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.accountName)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 4)
                control()
            }
            if let caption {
                Text(caption)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

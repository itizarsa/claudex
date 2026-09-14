import ClaudexCore
import ServiceManagement
import SwiftUI

/// The settings face of the popover. It replaces the account list rather than opening a window,
/// because everything here is one or two controls per line and a separate window for that is a
/// second thing to find and close.
struct SettingsPanel: View {
    @Bindable var state: PanelState

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            group("Rotation") {
                SettingRow(
                    title: "Switch automatically",
                    caption: "When the active account passes a threshold, sign the CLI into the account with the most headroom."
                ) {
                    Toggle("", isOn: setting(\.autoSwitchEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }

                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    ThresholdRow(
                        kind: kind,
                        fiveHour: threshold(kind, \.fiveHour),
                        weekly: threshold(kind, \.weekly),
                        onCommit: { state.saveSettings() }
                    )
                    .disabled(!state.settings.autoSwitchEnabled)
                    .opacity(state.settings.autoSwitchEnabled ? 1 : 0.45)
                }
            }

            group("CLI routing") {
                SettingRow(
                    title: "Route CLIs through Claudex",
                    caption: routingCaption
                ) { EmptyView() }

                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    RoutingRow(
                        kind: kind,
                        enabled: state.routingEnabled(kind),
                        state: state.routing.state(for: kind),
                        busy: state.routing.busy == kind,
                        onChange: { state.setRouting(kind, enabled: $0) }
                    )
                }
            }

            group("Notifications") {
                SettingRow(
                    title: "Notify on switch",
                    caption: "Routed CLIs switch on their next request. An unrouted CLI keeps using its own signed-in account."
                ) {
                    Toggle("", isOn: setting(\.notificationsEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }

            group("Polling") {
                IntervalRow(title: "Active account minimum", seconds: setting(\.activePollSeconds), choices: [300, 600, 900, 1800])
                IntervalRow(title: "Other accounts", seconds: setting(\.idlePollSeconds), choices: [300, 600, 900, 1800])
            }

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

    /// Says the two things a user cannot discover from the switch: that this writes to files
    /// they own, and that the routing only holds while claudex is running.
    private var routingCaption: String {
        """
        Writes ~/.claude/settings.json and ~/.codex/config.toml so a running session picks up \
        an account switch on its next request. Requests fail while Claudex is not running. \
        Turning a provider off restores its file and disables CLI account switching.
        """
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

    // MARK: - Bindings

    /// Toggles and pickers commit one value at a time, so each write is also a save.
    private func setting<Value>(_ keyPath: WritableKeyPath<ClaudexCore.Settings, Value>) -> Binding<Value> {
        Binding(
            get: { state.settings[keyPath: keyPath] },
            set: { state.updateSetting(keyPath, $0) }
        )
    }

    /// Sliders emit a value per pixel of travel, which is not a write worth making to disk.
    /// The binding updates memory only; `onCommit` saves when the drag ends.
    private func threshold(
        _ kind: ProviderKind,
        _ keyPath: WritableKeyPath<ProviderThresholds, Double>
    ) -> Binding<Double> {
        Binding(
            get: { state.settings.thresholds(for: kind)[keyPath: keyPath] },
            set: { state.updateThreshold(kind, keyPath, $0) }
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

/// One provider's routing switch, with the file state underneath it.
///
/// The switch is the only control, but it cannot always be flipped: a config someone else set
/// is reported rather than replaced, because claudex overwriting an organisation's gateway
/// would be a silent change to how their work reaches a vendor.
struct RoutingRow: View {
    let kind: ProviderKind
    let enabled: Bool
    let state: RoutingController.State
    let busy: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        SettingRow(title: kind.displayName, caption: caption) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Toggle("", isOn: Binding(get: { enabled }, set: onChange))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(isBlocked)
            }
        }
        .opacity(isBlocked ? 0.6 : 1)
    }

    private var isBlocked: Bool {
        if case .blocked = state { return true }
        return false
    }

    private var caption: String? {
        switch state {
        case .off: return enabled ? "Waiting for routing setup." : "Direct mode. Claudex account changes do not affect this CLI."
        case .on: return "Routed. Sessions already running switch accounts on their next request."
        case .needsRepair: return "Configured for a Claudex that is no longer listening. Turn routing on to repair."
        case .blocked(let reason): return "\(reason). Claudex will not change it."
        case .failed(let message): return message
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

/// Both thresholds for one provider. The numbers sit beside the label rather than under the
/// sliders so the pair reads as one sentence: over either of these, hand over.
struct ThresholdRow: View {
    let kind: ProviderKind
    @Binding var fiveHour: Double
    @Binding var weekly: Double
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.displayName)
                .font(Theme.accountName)
                .foregroundStyle(Theme.primaryText)
            slider("Session", value: $fiveHour)
            slider("Weekly", value: $weekly)
        }
    }

    private func slider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 42, alignment: .leading)
            Slider(value: value, in: 50...100, step: 5) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.mini)
            Text("\(Int(value.wrappedValue))%")
                .font(Theme.percent(11))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

/// Poll intervals as a short list rather than a free number: the useful values are few, and a
/// field accepting five seconds would only be a way to get rate limited.
struct IntervalRow: View {
    let title: String
    @Binding var seconds: Double
    let choices: [Double]

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.accountName)
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 4)
            Picker("", selection: $seconds) {
                ForEach(choices, id: \.self) { choice in
                    Text(Self.label(choice)).tag(choice)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
        }
    }

    private static func label(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m"
    }
}

import ClaudexCore
import SwiftUI

struct UsagePopover: View {
    @Bindable var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.showingSettings {
                SettingsPanel(state: state)
            } else {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    section(kind)
                }
            }

            if let notice = state.notice {
                Text(notice)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: Theme.popoverWidth)
        .background(Theme.popoverTint)
        .background(VisualEffectBackground())
        .animation(Theme.transition, value: state.showingSettings)
    }

    // MARK: - Sections

    private func section(_ kind: ProviderKind) -> some View {
        let accounts = state.accounts(for: kind)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProviderMark(kind: kind)
                Text(kind.displayName.uppercased())
                    .font(Theme.sectionHeader)
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            .padding(.leading, 2)

            if accounts.isEmpty {
                EmptyProviderCard(kind: kind)
            } else {
                VStack(spacing: 6) {
                    ForEach(accounts) { account in
                        AccountCard(
                            account: account,
                            showsActiveMark: accounts.count > 1,
                            isSwitching: state.engine.switchingAccount == account.id
                        ) {
                            state.switchTo(account)
                        }
                    }
                }
                .animation(Theme.transition, value: accounts.first?.id)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                TextButton(title: "Refresh") {
                    state.refresh()
                }
                Spacer()
                IconButton(
                    systemName: "gearshape",
                    help: state.showingSettings ? "Back to accounts" : "Settings"
                ) {
                    state.toggleSettings()
                }
                Spacer()
                TextButton(title: "Quit") { state.quit() }
            }
        }
    }

}

// MARK: - Account card

/// One account is one elevated surface. Grouping the two windows inside a card is what makes
/// a multi-account panel scannable: the eye lands on a block, not on a run of hairlines.
struct AccountCard: View {
    let account: UsageAccount
    /// False for the only account of a provider, where marking the active one says nothing.
    let showsActiveMark: Bool
    let isSwitching: Bool
    let onSwitch: () -> Void
    @State private var hovering = false

    private var isSwitchable: Bool { showsActiveMark && !account.isActive && !isSwitching }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let snapshot = account.snapshot {
                WindowRow(
                    label: "Session",
                    window: snapshot.fiveHour,
                    emphasis: true,
                    unavailableResetText: "Starts next message"
                )
                WindowRow(
                    label: "Weekly",
                    window: snapshot.weekly,
                    emphasis: false,
                    unavailableResetText: nil
                )
            } else {
                Text("No usage reported yet.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }

            if account.health != "ready" {
                Text("tokenmaxx reports this account as \(account.health).")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.cardPaddingH)
        .padding(.vertical, Theme.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if isSwitchable { onSwitch() } }
        .help(isSwitchable ? "Route \(account.provider.displayName) through this account" : "")
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(isSwitchable && hovering ? Theme.cardHover : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: Theme.cardStrokeWidth)
        )
        // The active account is marked at the card's edge: a rail reads as a property of the
        // whole card.
        .overlay(alignment: .leading) {
            if showsActiveMark && account.isActive {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: Theme.activeRailWidth)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .opacity(isSwitching ? 0.62 : 1)
        .onHover { hovering = $0 }
        .animation(Theme.transition, value: hovering)
        .animation(Theme.transition, value: isSwitching)
        .animation(Theme.transition, value: account)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AliasBadge(text: account.badge, filled: account.isActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.email)
                    .font(Theme.accountName)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(account.plan)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isSwitching {
                Tag(text: "Switching…")
            } else if isSwitchable && hovering {
                Tag(text: "Switch")
            }
        }
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.activeTag)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
    }
}

struct AliasBadge: View {
    let text: String
    let filled: Bool

    var body: some View {
        Text(text)
            .font(Theme.alias)
            .foregroundStyle(filled ? Theme.accent : Theme.secondaryText)
            .frame(width: Theme.aliasBadgeSize, height: Theme.aliasBadgeSize)
            .background(
                Circle().fill(filled ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.06))
            )
    }
}

/// One window: label, reset context, and percentage on one line with the bar under it.
struct WindowRow: View {
    let label: String
    let window: UsageWindow
    let emphasis: Bool
    let unavailableResetText: String?

    var body: some View {
        // Reset timing belongs to its window label. The quiet chip keeps that relationship
        // visible without competing with the percentage.
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(Theme.windowLabel)
                    .foregroundStyle(emphasis ? Theme.primaryText : Theme.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let resetText {
                    Text(resetText)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                }

                Spacer()

                Text(window.percentText)
                    .font(Theme.percent(Theme.percentSize))
                    .foregroundStyle(window.severity.tone)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            UsageBar(window: window)
        }
    }

    private var resetText: String? {
        let reset = window.resetText
        return reset.isEmpty ? unavailableResetText : reset
    }
}

/// Fill is usage; the notch is how far the clock has moved through the window. Fill behind the
/// notch means the window refills faster than it is being spent.
struct UsageBar: View {
    let window: UsageWindow
    private var height: CGFloat { Theme.barHeight }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.track)

                if window.percent != nil {
                    Capsule(style: .continuous)
                        .fill(window.severity.tone)
                        .frame(width: width * window.fraction)
                        .animation(.easeInOut(duration: 0.6), value: window.fraction)
                }

                if let elapsed = window.elapsed {
                    // Inside the bar rather than proud of it: the row reads as one hairline,
                    // and anything standing above it made the filled bar look twice its height.
                    // Tinted by pace: position says how much time is gone, colour says whether
                    // the spend rate will survive it.
                    Rectangle()
                        .fill(window.pace?.tone ?? Theme.primaryText)
                        .frame(width: Theme.barMarkerWidth, height: height)
                        .offset(x: min(width - Theme.barMarkerWidth,
                                       max(0, round(width * elapsed) - Theme.barMarkerWidth / 2)))
                }
            }
        }
        .frame(height: height)
    }
}

struct SkeletonRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        // Mirrors WindowRow's two lines at the same heights. A skeleton that is shorter than
        // what replaces it makes the whole popover resize when the first reading lands.
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: Theme.barRadius, style: .continuous)
                .fill(Theme.track)
                .frame(width: 54, height: 12)
            Capsule(style: .continuous)
                .fill(Theme.track)
                .frame(height: Theme.barHeight)
        }
        .opacity(shimmer ? 0.45 : 0.85)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = !reduceMotion }
    }
}

/// An empty provider is a setup step, not a blank space.
struct EmptyProviderCard: View {
    let kind: ProviderKind

    var body: some View {
        Text("Run tokenmaxx login \(kind.rawValue) to add an account.")
            .font(Theme.caption)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
    }
}

// MARK: - Controls

struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 22
    var glyphSize: CGFloat = 10
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .bold))
                .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0.045))
                )
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .onHover { hovering = $0 }
        .animation(Theme.transition, value: hovering)
    }
}

struct TextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(Theme.transition, value: hovering)
    }
}

/// Presses need physical feedback, and transform-based scaling keeps it cheap.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

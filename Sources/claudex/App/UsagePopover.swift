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
        // The live account sits at the top, because it is the one reading a person opens the
        // panel for; the rest keep their stored order under it. Sorted here rather than in the
        // store, where `order` is the rotation order and must not move when the CLI switches.
        let accounts = state.accounts(for: kind)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProviderMark(kind: kind)
                Text(kind.displayName.uppercased())
                    .font(Theme.sectionHeader)
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                IconButton(
                    systemName: "plus",
                    help: "Add a \(kind.displayName) account by signing in to it in your browser",
                    size: 26,
                    glyphSize: 11
                ) {
                    state.signIn(kind)
                }
                .disabled(state.isBusy)
            }
            .padding(.leading, 2)

            if accounts.isEmpty {
                EmptyProviderCard(kind: kind, busy: state.signingIn == kind, onSignIn: { state.signIn(kind) })
            } else {
                VStack(spacing: 6) {
                    ForEach(accounts) { account in
                        AccountCard(
                            account: account,
                            state: state.accountState(account),
                            isActive: state.isActive(account),
                            showsActiveMark: accounts.count > 1,
                            isRefreshing: state.isPolling(account),
                            isSwitching: state.switchingAccount == account.id,
                            canSwitch: accounts.count > 1 && state.switchingAccount == nil,
                            onAliasChange: { state.setAlias($0, for: account) },
                            onActivate: { state.select(account) }
                        )
                        .contextMenu {
                            if !state.isActive(account) {
                                Button("Route the CLI through \(account.label)") { state.select(account) }
                            }
                            Button("Remove \(account.label)", role: .destructive) { state.remove(account) }
                        }
                    }
                }
                .animation(Theme.transition, value: accounts.first(where: { state.isActive($0) })?.id)
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
                    help: state.showingSettings ? "Back to accounts" : "Thresholds, notifications, startup"
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
    let account: Account
    let state: AccountState
    let isActive: Bool
    /// False for the only account of a provider: with nothing to switch to, marking one card
    /// as the live one says nothing.
    let showsActiveMark: Bool
    let isRefreshing: Bool
    let isSwitching: Bool
    /// False for the only account of a provider, where there is nothing to switch to, and while
    /// another switch is already running.
    let canSwitch: Bool
    let onAliasChange: (String) -> Void
    let onActivate: () -> Void
    @State private var hovering = false
    @State private var editingAlias = false
    @State private var aliasDraft = ""
    @FocusState private var aliasFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch state {
            case .ok(let snapshot):
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
            case .loading, .idle:
                SkeletonRow()
                SkeletonRow()
            case .failed(let message):
                Text(ErrorPresenter.message(message))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.cardPaddingH)
        .padding(.vertical, Theme.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The card is the target: a row that already says which account it is, is a better
        // place to click than a button repeating the name. Only an inactive one is clickable,
        // so the active card does not invite a switch to where the CLI already is.
        .onTapGesture { if isSwitchable { onActivate() } }
        .help(isSwitchable ? "Sign the \(account.provider.displayName) CLI into \(account.label)" : "")
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(hovering ? Theme.cardHover : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: Theme.cardStrokeWidth)
        )
        // The live account is marked at the card's edge rather than by a tag in the header.
        // A rail is read as a property of the whole card, which is what being signed in is,
        // and it leaves the header's one tag slot free for the switch.
        .overlay(alignment: .leading) {
            if showsActiveMark && isActive {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: Theme.activeRailWidth)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        // Every account is drawn at full strength: the rail says which one is live, and
        // dimming the others made a two-account panel look half broken. A poll in flight dims
        // the card it is updating, which is cheaper to look at than a teardown.
        .opacity(isRefreshing || isSwitching ? 0.62 : 1)
        .onHover { hovering = $0 }
        .animation(Theme.transition, value: hovering)
        .animation(Theme.transition, value: isRefreshing)
        .animation(Theme.transition, value: isSwitching)
        .animation(Theme.transition, value: state)
    }

    private var isSwitchable: Bool { canSwitch && !isActive && !isSwitching }

    private var header: some View {
        HStack(spacing: 8) {
            aliasControl
            // Two lines rather than one run of text: the person names the seat, and the plan
            // and email below are the fine print saying which seat it is. On one line they
            // competed for the same weight.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(account.label)
                        .font(Theme.accountName)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    // The organisation trails the name rather than leading it, so every card's
                    // name starts at the same place and the column scans as a list of people.
                    // It also truncates first: a clipped organisation still says which seat
                    // this is, a clipped name does not.
                    if let organization = account.identity.organizationTag {
                        Chip(text: organization)
                    }
                }
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            // Which account is live is said by the rail down the card's edge, not by a tag, so
            // this slot never holds two labels at once. What is left is the one thing that is
            // an action: switching, in progress or on offer.
            if isSwitching {
                Tag(text: "Switching…")
            } else if isSwitchable && hovering {
                Tag(text: "Switch")
            }
        }
    }

    private var subtitle: String {
        let email = account.identity.email
        return email.isEmpty ? account.identity.plan : "\(account.identity.plan) · \(email)"
    }

    /// The badge is the only place the menu-bar alias is visible, so it is also where it is
    /// edited. Editing in place avoids a settings window for a two-character field.
    @ViewBuilder private var aliasControl: some View {
        if editingAlias {
            TextField("", text: $aliasDraft)
                .textFieldStyle(.plain)
                .font(Theme.alias)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.accent)
                .focused($aliasFocused)
                .frame(width: Theme.aliasBadgeSize, height: Theme.aliasBadgeSize)
                .background(Circle().fill(Theme.accent.opacity(0.15)))
                .overlay(Circle().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
                .onChange(of: aliasDraft) { _, new in
                    if new.count > 2 { aliasDraft = String(new.prefix(2)) }
                }
                .onSubmit(commitAlias)
                .onExitCommand { editingAlias = false }
                .onChange(of: aliasFocused) { _, focused in
                    if !focused { commitAlias() }
                }
        } else {
            Button {
                aliasDraft = account.alias ?? ""
                editingAlias = true
                aliasFocused = true
            } label: {
                AliasBadge(text: account.badge, filled: isActive)
            }
            .buttonStyle(PressableButtonStyle())
            .help("Set the two-character alias the menu bar ring shows")
        }
    }

    private func commitAlias() {
        editingAlias = false
        onAliasChange(aliasDraft)
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

/// The organisation beside an account's name. Deliberately unlike `Tag`: greyed and square
/// where the tag is accented and capsuled, because one is a fact about the seat and the other
/// is an action offered on it.
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.chip)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
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
    let busy: Bool
    let onSignIn: () -> Void
    @State private var hovering = false

    var body: some View {
        // One quiet row, the height of a control rather than of a card: the absence should not
        // take up more room than the account that replaces it, and a dashed outline of a card
        // that isn't there reads as damage. Plain words plus a plus, centred.
        HStack(spacing: 6) {
            Image(systemName: busy ? "ellipsis" : "plus")
                .font(.system(size: 9, weight: .bold))
            Text(busy ? "Signing in…" : "Sign in to \(kind.displayName)")
                .font(Theme.accountName)
        }
        .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { if !busy { onSignIn() } }
        .help("Sign in to a \(kind.displayName) account in your browser")
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(hovering ? Theme.cardHover : Color.primary.opacity(0.03))
        )
        .opacity(busy ? 0.62 : 1)
        .onHover { hovering = $0 && !busy }
        .animation(Theme.transition, value: hovering)
        .animation(Theme.transition, value: busy)
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

import SwiftUI

struct UsagePopover: View {
    @Bindable var store: AccountStore
    let engine: UsageEngine
    @State private var notice: String?
    @State private var switchingAccount: UUID?
    @State private var showingSettings = false
    @State private var signingIn: ProviderKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showingSettings {
                SettingsPanel(store: store) { showingSettings = false }
            } else {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    section(kind)
                }
            }

            if let notice {
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
        .animation(Theme.transition, value: showingSettings)
    }

    // MARK: - Sections

    private func section(_ kind: ProviderKind) -> some View {
        let accounts = store.accounts(for: kind)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(kind.displayName.uppercased())
                    .font(Theme.sectionHeader)
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                IconButton(
                    systemName: "plus",
                    help: "Add a \(kind.displayName) account by signing in to it in your browser"
                ) {
                    signIn(kind)
                }
                .disabled(isBusy)
            }
            .padding(.leading, 2)

            if accounts.isEmpty {
                EmptyProviderCard(
                    kind: kind,
                    busy: signingIn == kind,
                    onSignIn: { signIn(kind) }
                )
            } else {
                VStack(spacing: 6) {
                    ForEach(accounts) { account in
                        AccountCard(
                            account: account,
                            state: store.state(account.id),
                            isActive: store.isActive(account),
                            showsActiveTag: accounts.count > 1,
                            isRefreshing: engine.isPolling(account.id),
                            isSwitching: switchingAccount == account.id,
                            canSwitch: accounts.count > 1 && switchingAccount == nil,
                            onAliasChange: { store.setAlias($0, for: account) },
                            onActivate: { activate(account) }
                        )
                        .contextMenu {
                            if !store.isActive(account) {
                                Button("Sign the CLI into \(account.label)") { activate(account) }
                            }
                            Button("Remove \(account.label)", role: .destructive) { store.remove(account) }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                TextButton(title: "Refresh") {
                    notice = nil
                    engine.refreshAll()
                }
                Spacer()
                IconButton(
                    systemName: "gearshape",
                    help: showingSettings ? "Back to accounts" : "Thresholds, notifications, startup"
                ) {
                    notice = nil
                    showingSettings.toggle()
                }
                Spacer()
                TextButton(title: "Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    // MARK: - Actions

    /// Signing the CLI into another account rotates tokens on both sides of the swap, so the
    /// snapshot for every account of that provider is stale the moment it succeeds. Refreshing
    /// the provider rather than the one card is what keeps the panel honest.
    private func activate(_ account: Account) {
        guard !store.isActive(account), switchingAccount == nil else { return }
        switchingAccount = account.id
        notice = nil
        Task {
            defer { switchingAccount = nil }
            do {
                try await Switcher.activate(account, in: store)
                // A choice made by hand outranks the rule, and starts the cooldown afresh so
                // the rotator does not undo it on the next poll.
                engine.rotator.noteManualSwitch(account.provider)
                engine.refreshAll()
            } catch {
                notice = ErrorPresenter.message(error)
            }
        }
    }

    private var isBusy: Bool { signingIn != nil }

    /// The CLI's own login runs hidden against a throwaway config directory and opens the
    /// browser itself, so the account currently signed in is untouched and claudex owns no OAuth
    /// code. The new account is added inactive: adding is not a request to switch.
    private func signIn(_ kind: ProviderKind) {
        guard !isBusy else { return }
        signingIn = kind
        notice = "Finish the sign-in in your browser. Claudex is waiting for it."
        Task {
            defer { signingIn = nil }
            do {
                let result = try await SandboxedLogin.run(kind, into: store)
                Log.write("panel: sign-in returned \(result.account.label), already known \(result.wasAlreadyKnown)")
                notice = result.wasAlreadyKnown
                    ? "\(result.account.label) was already tracked. Its credentials are up to date."
                    : "Added \(result.account.label). It is not active — switch to it when you want it."
                engine.refreshAll()
            } catch {
                Log.write("panel: sign-in failed — \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
                notice = ErrorPresenter.message(error)
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
    let showsActiveTag: Bool
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
                WindowRow(label: "Session", window: snapshot.fiveHour, emphasis: true)
                WindowRow(label: "Weekly", window: snapshot.weekly, emphasis: false)
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
        // Every account is drawn at full strength: the Active tag says which one is live, and
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
            Text(account.label)
                .font(Theme.accountName)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Text(account.identity.plan)
                .font(Theme.plan)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            // One slot, three readings: where the account is live, that it is being made live,
            // or — under the pointer — that it can be.
            if isSwitching {
                Tag(text: "Switching…")
            } else if showsActiveTag && isActive {
                Tag(text: "Active")
            } else if isSwitchable && hovering {
                Tag(text: "Switch")
            }
        }
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

/// One window: label and percentage on a line, the bar under it, the reset time beneath.
struct WindowRow: View {
    let label: String
    let window: UsageWindow
    let emphasis: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(Theme.windowLabel)
                    .foregroundStyle(Theme.primaryText)
                if !emphasis {
                    Text("Weekly")
                        .font(Theme.pill)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                Text(window.percentText)
                    .font(Theme.percent(Theme.percentSize))
                    .foregroundStyle(window.severity.tone)
            }

            UsageBar(window: window)

            if !window.resetText.isEmpty {
                Text(window.resetText)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
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
                        .frame(width: max(window.fraction > 0 ? height : 0, width * window.fraction))
                        .animation(.easeInOut(duration: 0.6), value: window.fraction)
                }

                if let elapsed = window.elapsed {
                    // Proud of the bar on both sides, the same way the menu-bar notch crosses
                    // the ring, so the two readings of elapsed time look like one idea. Tinted
                    // by pace: position says how much time is gone, colour says whether the
                    // spend rate will survive it.
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(window.pace?.tone ?? Theme.primaryText)
                        .frame(width: Theme.barMarkerWidth, height: height + 4)
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
        // Mirrors WindowRow's three lines at the same heights. A skeleton that is shorter than
        // what replaces it makes the whole popover resize when the first reading lands.
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: Theme.barRadius, style: .continuous)
                .fill(Theme.track)
                .frame(width: 54, height: 12)
            Capsule(style: .continuous)
                .fill(Theme.track)
                .frame(height: Theme.barHeight)
            RoundedRectangle(cornerRadius: Theme.barRadius, style: .continuous)
                .fill(Theme.track)
                .frame(width: 92, height: 10)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No \(kind.displayName) account yet")
                .font(Theme.accountName)
                .foregroundStyle(Theme.primaryText)
            Text(kind == .claude
                 ? "Sign in to a claude.ai account. Claudex signs the CLI into it for you."
                 : "Sign in to a ChatGPT account. Claudex signs the CLI into it for you.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextButton(title: busy ? "Signing in…" : "Sign in", action: onSignIn)
                .disabled(busy)
        }
        .padding(.horizontal, Theme.cardPaddingH)
        .padding(.vertical, Theme.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
    }
}

// MARK: - Controls

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
                .frame(width: 22, height: 22)
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

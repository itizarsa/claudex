import SwiftUI

struct UsagePopover: View {
    @Bindable var store: AccountStore
    let engine: UsageEngine
    @State private var notice: String?
    @State private var busyProvider: ProviderKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ProviderKind.allCases, id: \.self) { kind in
                section(kind)
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
        .background(.ultraThinMaterial)
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
                IconButton(systemName: "plus", help: "Add the account this CLI is signed into") {
                    importCurrent(kind)
                }
                .disabled(busyProvider != nil)
            }
            .padding(.leading, 2)

            if accounts.isEmpty {
                EmptyProviderCard(kind: kind, busy: busyProvider == kind) { importCurrent(kind) }
            } else {
                VStack(spacing: 7) {
                    ForEach(accounts) { account in
                        AccountCard(
                            account: account,
                            state: store.state(account.id),
                            isActive: store.isActive(account),
                            showsActiveTag: accounts.count > 1,
                            isRefreshing: engine.isPolling(account.id),
                            onAliasChange: { store.setAlias($0, for: account) }
                        )
                        .contextMenu {
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
                TextButton(title: "Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    // MARK: - Actions

    private func importCurrent(_ kind: ProviderKind) {
        busyProvider = kind
        notice = nil
        Task {
            defer { busyProvider = nil }
            do {
                let result = try await CLIImport.importCurrent(kind, into: store)
                if result.wasAlreadyKnown {
                    notice = "\(result.account.label) was already tracked. Its credentials are up to date."
                }
                engine.refreshAll()
            } catch {
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
    let onAliasChange: (String) -> Void
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
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(hovering ? Theme.cardHover : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        // Inactive accounts stay legible: they lose emphasis, not readability. A poll in flight
        // dims the card it is updating, which is cheaper to look at than a teardown.
        .opacity((isActive ? 1 : 0.78) * (isRefreshing ? 0.62 : 1))
        .onHover { hovering = $0 }
        .animation(Theme.transition, value: hovering)
        .animation(Theme.transition, value: isRefreshing)
        .animation(Theme.transition, value: state)
    }

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
            if showsActiveTag && isActive {
                Tag(text: "Active")
            }
        }
    }

    /// The badge is the only place the menu-bar alias is visible, so it is also where it is
    /// edited. Editing in place avoids a settings window for a two-character field.
    @ViewBuilder private var aliasControl: some View {
        if editingAlias {
            TextField("", text: $aliasDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.primaryText)
                .focused($aliasFocused)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                )
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
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(filled ? Theme.primaryText : Theme.secondaryText)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Color.white.opacity(filled ? 0.14 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: filled ? 0 : 1)
            )
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.pill)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
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
                    .foregroundStyle(emphasis ? Theme.primaryText : Theme.secondaryText)
                Spacer()
                Text(window.percentText)
                    .font(Theme.percent(emphasis ? 17 : 14))
                    .tracking(-0.3)
                    .foregroundStyle(window.severity.tone)
            }

            UsageBar(window: window)

            if !window.resetText.isEmpty {
                Text(window.resetText)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiaryText)
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
                RoundedRectangle(cornerRadius: Theme.barRadius, style: .continuous)
                    .fill(Theme.track)

                if window.percent != nil {
                    RoundedRectangle(cornerRadius: Theme.barRadius, style: .continuous)
                        .fill(window.severity.tone)
                        .frame(width: max(window.fraction > 0 ? height : 0, width * window.fraction))
                }

                if let elapsed = window.elapsed {
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: height + 4)
                        .offset(x: min(width - 2, max(0, width * elapsed - 1)))
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
            RoundedRectangle(cornerRadius: Theme.barRadius, style: .continuous)
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
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No \(kind.displayName) account yet")
                .font(Theme.accountName)
                .foregroundStyle(Theme.primaryText)
            Text(kind == .claude
                 ? "Add the claude.ai account your CLI is signed into."
                 : "Add the ChatGPT account your CLI is signed into.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextButton(title: busy ? "Adding…" : "Add current account", action: action)
                .disabled(busy)
        }
        .padding(Theme.cardPadding)
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
                        .fill(Color.white.opacity(hovering ? 0.1 : 0.045))
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
                        .fill(Color.white.opacity(hovering ? 0.08 : 0))
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

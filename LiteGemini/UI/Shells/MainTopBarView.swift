import SwiftUI

// MARK: - MainTopBarView

/// Prototype-locked `Left Recent` Liquid Glass top bar for the main native window.
///
/// Layout (left to right):
/// - Bare macOS traffic-light clearance (`~74pt` leading inset — never enclosed inside a pill)
/// - Floating `Recent ▾` Liquid Glass capsule (collapses cleanly below `460pt` window width)
/// - Draggable titlebar spacer (`WindowDragArea`, supporting drag and double-click zoom)
/// - Paired `[Temporary Chat · + New Chat]` Liquid Glass capsule (strictly icon-only temp toggle)
/// - Standalone `28pt` circular Account Avatar button (zero `?0` index text)
struct MainTopBarView: View {

    @ObservedObject var workspace: MainWorkspaceStore
    @ObservedObject private var session: ChatSessionStore
    let onAddAccount: () -> Void

    @State private var measuredWidth: CGFloat = 800
    @State private var isRecentPopoverPresented = false
    @State private var isAccountPopoverPresented = false
    @State private var isHoveringRecent = false
    @State private var isHoveringTemp = false
    @State private var isHoveringNewChat = false
    @State private var isHoveringAvatar = false

    private var isCompactWidth: Bool {
        measuredWidth < LiquidGlassMetrics.compactTopBarBreakpoint
    }

    init(
        workspace: MainWorkspaceStore,
        onAddAccount: @escaping () -> Void
    ) {
        self._workspace = ObservedObject(wrappedValue: workspace)
        self._session = ObservedObject(wrappedValue: workspace.session)
        self.onAddAccount = onAddAccount
    }

    var body: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 10) {
                // Leave bare leading clearance for macOS traffic lights without enclosing them in a pill.
                Color.clear
                    .frame(width: LiquidGlassMetrics.trafficLightLeadingInset, height: 1)
                    .allowsHitTesting(false)

                recentTriggerButton

                Spacer(minLength: 8)

                rightActionCluster
            }
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: LiquidGlassMetrics.topBarHeight)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: TopBarWidthPreferenceKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(TopBarWidthPreferenceKey.self) { width in
            if abs(width - measuredWidth) > 0.5 {
                measuredWidth = width
            }
        }
    }

    // MARK: - Left Cluster

    private var recentTriggerButton: some View {
        Button {
            isRecentPopoverPresented.toggle()
        } label: {
            HStack(spacing: isCompactWidth ? 4 : 5) {
                if isCompactWidth {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Recent")
                        .font(.system(size: 12.5, weight: .medium))
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary.opacity(isHoveringRecent || isRecentPopoverPresented ? 0.96 : 0.84))
            .padding(.horizontal, isCompactWidth ? 9 : 11)
            .frame(height: LiquidGlassMetrics.topBarCapsuleHeight)
            .glassToolbarButton()
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringRecent = hovering
            }
        }
        .help(String(localized: "Recent Chats"))
        .accessibilityLabel(Text("Recent Chats"))
        .popover(isPresented: $isRecentPopoverPresented, arrowEdge: .bottom) {
            RecentChatsPopover(store: workspace) {
                isRecentPopoverPresented = false
            }
        }
    }

    // MARK: - Right Cluster

    private var rightActionCluster: some View {
        LiquidGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                pairedActionCapsule
                accountAvatarButton
            }
        }
    }

    private var pairedActionCapsule: some View {
        HStack(spacing: 2) {
            temporaryChatButton

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(width: 1, height: 14)

            newChatButton
        }
        .padding(.horizontal, 3)
        .frame(height: LiquidGlassMetrics.topBarCapsuleHeight)
        .glassCapsule()
    }

    /// Icon-only Temporary Chat toggle: signals active state strictly through icon foreground
    /// and subtle inner background tint without ever adding text or shifting layout.
    private var temporaryChatButton: some View {
        let isActive = session.isTemporaryChat

        return Button {
            let nextState = !isActive
            Task {
                await session.setTemporaryChat(nextState)
            }
        } label: {
            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        isActive
                            ? LiquidGlassColors.tempActiveTint
                            : (isHoveringTemp ? LiquidGlassColors.hoverHighlight : Color.clear)
                    )

                TemporaryChatGhostShape()
                    .fill(
                        isActive
                            ? LiquidGlassColors.tempActiveAccent
                            : Color.primary.opacity(isHoveringTemp ? 0.95 : 0.72),
                        style: FillStyle(eoFill: true)
                    )
                    .frame(width: 14, height: 14)
            }
            .frame(width: 28, height: 24)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringTemp = hovering
            }
        }
        .help(isActive ? String(localized: "Temporary Chat: On") : String(localized: "Temporary Chat: Off"))
        .accessibilityLabel(Text("Temporary Chat"))
        .accessibilityValue(isActive ? Text("On") : Text("Off"))
    }

    private var newChatButton: some View {
        Button {
            Task {
                await workspace.startNewChat()
            }
        } label: {
            ZStack {
                Capsule(style: .continuous)
                    .fill(isHoveringNewChat ? LiquidGlassColors.hoverHighlight : Color.clear)

                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(isHoveringNewChat ? 0.96 : 0.78))
            }
            .frame(width: 28, height: 24)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringNewChat = hovering
            }
        }
        .help(String(localized: "New Chat"))
        .accessibilityLabel(Text("New Chat"))
    }

    private var accountAvatarButton: some View {
        Button {
            isAccountPopoverPresented.toggle()
        } label: {
            AccountAvatarView(
                account: workspace.activeAccount,
                size: LiquidGlassMetrics.accountAvatarSize
            )
            .scaleEffect(isHoveringAvatar ? 1.04 : 1.0)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringAvatar = hovering
            }
        }
        .help(accountButtonHelpText)
        .accessibilityLabel(accountButtonAccessibilityLabel)
        .popover(isPresented: $isAccountPopoverPresented, arrowEdge: .bottom) {
            AccountPopover(
                store: workspace,
                onAddAccount: onAddAccount,
                onDismiss: {
                    isAccountPopoverPresented = false
                }
            )
        }
    }

    private var accountButtonHelpText: String {
        if let email = workspace.activeAccount?.email, !email.isEmpty {
            return email
        }
        return String(localized: "Account")
    }

    private var accountButtonAccessibilityLabel: Text {
        if let name = workspace.activeAccount?.displayName, !name.isEmpty {
            return Text(name)
        }
        if let email = workspace.activeAccount?.email, !email.isEmpty {
            return Text(email)
        }
        return Text("Account")
    }
}

// MARK: - TopBarWidthPreferenceKey

private nonisolated struct TopBarWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 800

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

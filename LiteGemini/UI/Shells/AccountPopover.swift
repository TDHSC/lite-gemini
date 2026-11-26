import SwiftUI

// MARK: - AccountAvatarView

/// Circular account avatar displaying `AccountScope.avatarURL` via `AsyncImage` and falling
/// back cleanly to a crisp monogram circle (never rendering any `?0` index label).
struct AccountAvatarView: View {

    let account: AccountScope?
    var size: CGFloat = LiquidGlassMetrics.accountAvatarSize

    var body: some View {
        Group {
            if let avatarURL = account?.avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        monogramFallback
                    @unknown default:
                        monogramFallback
                    }
                }
            } else {
                monogramFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: LiquidGlassMetrics.hairlineWidth)
        )
    }

    private var monogramFallback: some View {
        ZStack {
            Circle()
                .fill(monogramBackground)

            if let account {
                Text(account.initials)
                    .font(.system(size: max(10, size * 0.44), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: max(11, size * 0.44), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var monogramBackground: LinearGradient {
        guard let account else {
            return LinearGradient(
                colors: [Color.primary.opacity(0.12), Color.primary.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        // Deterministic calm hue derived from scopeId so multi-account monograms stay distinguishable.
        let palette: [(Color, Color)] = [
            (Color(red: 0.24, green: 0.51, blue: 0.96), Color(red: 0.16, green: 0.39, blue: 0.85)),
            (Color(red: 0.51, green: 0.37, blue: 0.92), Color(red: 0.38, green: 0.25, blue: 0.78)),
            (Color(red: 0.14, green: 0.62, blue: 0.55), Color(red: 0.09, green: 0.48, blue: 0.43)),
            (Color(red: 0.84, green: 0.45, blue: 0.24), Color(red: 0.71, green: 0.33, blue: 0.15)),
            (Color(red: 0.78, green: 0.31, blue: 0.52), Color(red: 0.62, green: 0.21, blue: 0.40))
        ]
        let hashByte = account.scopeId.utf8.first.map(Int.init) ?? 0
        let pair = palette[hashByte % palette.count]
        return LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - AccountPopover

/// Multi-account switcher popover showing active `AccountScope` metadata (`displayName`,
/// `email`, `scopeId` prefix), available signed-in accounts, and an action to add another account.
struct AccountPopover: View {

    @ObservedObject var store: MainWorkspaceStore
    let onAddAccount: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredScopeId: String?
    @State private var isHoveringAddAccount = false

    private var availableAccounts: [AccountScope] {
        store.authState.availableAccounts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let active = store.activeAccount {
                activeAccountHeader(active)
            } else {
                signedOutHeader
            }

            if !availableAccounts.isEmpty {
                Divider()
                    .opacity(0.5)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 2)

                    ForEach(availableAccounts) { account in
                        accountRow(for: account)
                    }
                }
                .padding(6)
            }

            Divider()
                .opacity(0.5)

            addAccountButton
                .padding(6)
        }
        .frame(width: 268)
        .environment(\.colorScheme, colorScheme)
    }

    // MARK: - Subviews

    private func activeAccountHeader(_ account: AccountScope) -> some View {
        HStack(spacing: 10) {
            AccountAvatarView(account: account, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedDisplayName(for: account))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(account.email)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(String(account.scopeId.prefix(8)))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var signedOutHeader: some View {
        HStack(spacing: 10) {
            AccountAvatarView(account: nil, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Not Signed In")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Sign in with Google to sync chats.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private func accountRow(for account: AccountScope) -> some View {
        let isActive = store.activeAccount?.scopeId == account.scopeId
        let isHovered = hoveredScopeId == account.scopeId

        return Button {
            onDismiss()
            guard !isActive else {
                return
            }
            Task {
                await store.switchAccount(account)
            }
        } label: {
            HStack(spacing: 9) {
                AccountAvatarView(account: account, size: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(resolvedDisplayName(for: account))
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let displayName = account.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !displayName.isEmpty,
                       !account.email.isEmpty {
                        Text(account.email)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                        .accessibilityLabel(Text("Active Account"))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? LiquidGlassColors.hoverHighlight : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredScopeId = hovering ? account.scopeId : (hoveredScopeId == account.scopeId ? nil : hoveredScopeId)
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var addAccountButton: some View {
        Button {
            onDismiss()
            onAddAccount()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                Text("Add Another Account…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHoveringAddAccount ? LiquidGlassColors.hoverHighlight : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringAddAccount = hovering
        }
    }

    // MARK: - Helpers

    private func resolvedDisplayName(for account: AccountScope) -> String {
        if let displayName = account.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if !account.email.isEmpty {
            return account.email
        }
        return String(localized: "Google Account")
    }
}

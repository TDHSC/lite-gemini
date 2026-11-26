import SwiftUI

// MARK: - RecentChatsPopover

/// Read-only Liquid Glass popover listing up to 20 recent conversations for the active account,
/// backed by `MainWorkspaceStore`'s SWR cache and server refresh.
struct RecentChatsPopover: View {

    @ObservedObject var store: MainWorkspaceStore
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredConversationId: String?
    @State private var isHoveringRefresh = false

    private static let maxDisplayedItems = 20

    private var displayedConversations: [ConversationSummary] {
        Array(store.recentConversations.prefix(Self.maxDisplayedItems))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Divider()
                .opacity(0.5)

            if displayedConversations.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(displayedConversations) { summary in
                            conversationRow(for: summary)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 284)
        .environment(\.colorScheme, colorScheme)
        .onAppear {
            if store.authState.isSignedIn, !store.isRefreshingRecent {
                Task {
                    await store.refreshRecentConversations()
                }
            }
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Recent Chats")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if store.isRefreshingRecent {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 28, height: 28)
            } else if store.authState.isSignedIn {
                Button {
                    Task {
                        await store.refreshRecentConversations()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(isHoveringRefresh ? 1.0 : 0.85))
                        .glassOrb(
                            size: 28,
                            variant: .clear,
                            tint: isHoveringRefresh ? LiquidGlassColors.hoverHighlight : nil,
                            interactive: true
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.14)) {
                        isHoveringRefresh = hovering
                    }
                }
                .help(String(localized: "Refresh Recent Chats"))
                .accessibilityLabel(Text("Refresh Recent Chats"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            if store.isRefreshingRecent {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            }

            Text("No Recent Chats")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Your recent Gemini conversations will appear here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
    }

    private func conversationRow(for summary: ConversationSummary) -> some View {
        let isActive = store.activeConversationId == summary.id
        let isHovered = hoveredConversationId == summary.id
        let displayTitle = summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Untitled")
            : summary.title

        return Button {
            onDismiss()
            Task {
                await store.selectConversation(id: summary.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                if summary.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                        .frame(width: 12)
                        .accessibilityLabel(Text("Pinned"))
                }

                Text(displayTitle)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                Text(Self.formattedRelativeDate(summary.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize()

                if isActive {
                    Circle()
                        .fill(LiquidGlassColors.sendButtonBlue)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowBackgroundColor(isActive: isActive, isHovered: isHovered))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredConversationId = hovering ? summary.id : (hoveredConversationId == summary.id ? nil : hoveredConversationId)
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func rowBackgroundColor(isActive: Bool, isHovered: Bool) -> Color {
        if isActive {
            return LiquidGlassColors.sendButtonBlue.opacity(0.14)
        }
        if isHovered {
            return LiquidGlassColors.hoverHighlight
        }
        return .clear
    }

    // MARK: - Formatting

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func formattedRelativeDate(_ date: Date, relativeTo now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 {
            return String(localized: "Now")
        }
        return relativeDateFormatter.localizedString(for: date, relativeTo: now)
    }
}

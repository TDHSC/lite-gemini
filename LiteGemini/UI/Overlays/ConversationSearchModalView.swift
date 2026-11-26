import AppKit
import SwiftUI

// MARK: - ConversationSearchItem

/// Unified result model displayed in the `⌘K` conversation search palette, merging instant local
/// cache hits (`isCloudMatch == false`) with cloud semantic search snippets (`isCloudMatch == true`).
nonisolated struct ConversationSearchItem: Identifiable, Equatable, Hashable, Sendable {

    let id: String
    let conversationId: String
    let title: String
    let snippet: String?
    let updatedAt: Date
    let isCloudMatch: Bool

    init(
        id: String? = nil,
        conversationId: String,
        title: String,
        snippet: String? = nil,
        updatedAt: Date,
        isCloudMatch: Bool = false
    ) {
        self.id = id ?? conversationId
        self.conversationId = conversationId
        self.title = title
        self.snippet = snippet
        self.updatedAt = updatedAt
        self.isCloudMatch = isCloudMatch
    }

    init(cachedMatch: CachedConversationSearchMatch) {
        self.init(
            id: cachedMatch.id,
            conversationId: cachedMatch.conversationId,
            title: cachedMatch.title,
            snippet: cachedMatch.snippet,
            updatedAt: cachedMatch.updatedAt,
            isCloudMatch: false
        )
    }

    init(summary: ConversationSummary) {
        self.init(
            id: summary.id,
            conversationId: summary.id,
            title: summary.title,
            snippet: nil,
            updatedAt: summary.updatedAt,
            isCloudMatch: false
        )
    }
}

// MARK: - ConversationSearchModalView

/// Centered `560pt × max 420pt` Liquid Glass `⌘K` command-palette overlay for instant local and
/// cloud conversation search.
///
/// Supports auto-focused typing, CJK IME-safe keyboard navigation (`↑`, `↓`, `↩`, `⎋`), unified
/// mouse hover/click selection, cloud loading indicator, empty states, and backdrop tap-to-dismiss.
struct ConversationSearchModalView: View {

    @Binding var query: String
    let results: [ConversationSearchItem]
    var isSearchingCloud: Bool = false
    var activeConversationId: String? = nil
    let onSelect: (ConversationSearchItem) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFieldFocused: Bool

    @State private var selectedItemId: String?
    @State private var keyboardScrollToken: UInt64 = 0

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedSelectedIndex: Int? {
        guard !results.isEmpty else {
            return nil
        }
        if let selectedItemId,
           let matchedIndex = results.firstIndex(where: { $0.id == selectedItemId }) {
            return matchedIndex
        }
        return 0
    }

    private var resolvedSelectedItem: ConversationSearchItem? {
        guard let idx = resolvedSelectedIndex, results.indices.contains(idx) else {
            return nil
        }
        return results[idx]
    }

    private var isIMEComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? any NSTextInputClient)?.hasMarkedText() ?? false
    }

    var body: some View {
        ZStack {
            // Translucent scrim backdrop with tap-to-dismiss.
            Color.black
                .opacity(colorScheme == .dark ? 0.34 : 0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    onDismiss()
                }
                .accessibilityHidden(true)

            modalCard
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncSelectionWithResults()
            isSearchFieldFocused = true
            Task { @MainActor in
                isSearchFieldFocused = true
            }
        }
        .onChange(of: results) { _, _ in
            syncSelectionWithResults()
        }
        .onKeyPress(.upArrow) {
            guard !isIMEComposing else { return .ignored }
            moveSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !isIMEComposing else { return .ignored }
            moveSelection(delta: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            guard !isIMEComposing else { return .ignored }
            onDismiss()
            return .handled
        }
        .onKeyPress(.return) {
            guard !isIMEComposing else { return .ignored }
            return selectHighlightedItem() ? .handled : .ignored
        }
    }

    // MARK: - Modal Card

    private var modalCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchInputBar

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(height: LiquidGlassMetrics.hairlineWidth)

            resultsBody

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(height: LiquidGlassMetrics.hairlineWidth)

            keyboardHintsFooter
        }
        .frame(maxWidth: 560)
        .frame(maxHeight: 420)
        .environment(\.colorScheme, colorScheme)
        .glassCard(cornerRadius: 18, variant: .regular)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.14),
            radius: 26,
            x: 0,
            y: 12
        )
    }

    // MARK: - Search Input Bar

    private var searchInputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(String(localized: "Search chats…"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5, weight: .regular))
                .foregroundStyle(.primary)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    guard !isIMEComposing else { return }
                    _ = selectHighlightedItem()
                }
                .accessibilityLabel(Text("Search chats"))

            if !query.isEmpty {
                Button {
                    query = ""
                    isSearchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear Search"))
                .accessibilityLabel(Text("Clear Search"))
            }

            if isSearchingCloud {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .frame(width: 18, height: 18)
                    .help(String(localized: "Searching cloud history…"))
                    .accessibilityLabel(Text("Searching cloud history"))
            }

            Button(action: onDismiss) {
                Text(verbatim: "esc")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(LiquidGlassColors.subtleHairline, lineWidth: LiquidGlassMetrics.hairlineWidth)
                    )
            }
            .buttonStyle(.plain)
            .help(String(localized: "Dismiss"))
            .accessibilityLabel(Text("Dismiss Search"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Results Body

    @ViewBuilder
    private var resultsBody: some View {
        if results.isEmpty {
            emptyStateView
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(results) { item in
                            let isSelected = resolvedSelectedItem?.id == item.id
                            let isCurrentChat = activeConversationId == item.conversationId
                            searchResultRow(
                                item: item,
                                isSelected: isSelected,
                                isCurrentChat: isCurrentChat
                            )
                            .id(item.id)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 318)
                .onChange(of: keyboardScrollToken) { _, _ in
                    guard let targetId = resolvedSelectedItem?.id else {
                        return
                    }
                    if reduceMotion {
                        proxy.scrollTo(targetId)
                    } else {
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(targetId)
                        }
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            if isSearchingCloud {
                ProgressView()
                    .controlSize(.small)
                Text("Searching conversations…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if !trimmedQuery.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No matching conversations")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Try a different keyword or phrase.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Search your conversations")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Type to search cached chats instantly and query your cloud history.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 44)
    }

    private func searchResultRow(
        item: ConversationSearchItem,
        isSelected: Bool,
        isCurrentChat: Bool
    ) -> some View {
        let displayTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Untitled")
            : item.title

        return Button {
            onSelect(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.isCloudMatch ? "cloud" : "bubble.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? LiquidGlassColors.sendButtonBlue
                            : Color.secondary.opacity(0.85)
                    )
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(
                            Self.highlightedText(
                                displayTitle,
                                matching: trimmedQuery,
                                fontSize: 13,
                                baseWeight: isSelected ? .semibold : .medium,
                                baseColor: Color.primary.opacity(isSelected ? 0.98 : 0.90)
                            )
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)

                        if isCurrentChat {
                            Circle()
                                .fill(LiquidGlassColors.sendButtonBlue)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel(Text("Current Chat"))
                        }

                        Spacer(minLength: 8)

                        if item.isCloudMatch {
                            Text("Cloud")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055))
                                )
                        }

                        Text(Self.formattedRelativeDate(item.updatedAt))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }

                    if let snippet = item.snippet?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !snippet.isEmpty {
                        Text(
                            Self.highlightedText(
                                snippet,
                                matching: trimmedQuery,
                                fontSize: 11.5,
                                baseWeight: .regular,
                                baseColor: Color.secondary
                            )
                        )
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? LiquidGlassColors.sendButtonBlue.opacity(colorScheme == .dark ? 0.20 : 0.12)
                            : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? LiquidGlassColors.sendButtonBlue.opacity(0.28) : Color.clear,
                        lineWidth: LiquidGlassMetrics.hairlineWidth
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                selectedItemId = item.id
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Footer

    private var keyboardHintsFooter: some View {
        HStack(spacing: 14) {
            shortcutHint(keys: "↑↓", label: String(localized: "Navigate"))
            shortcutHint(keys: "↩", label: String(localized: "Open"))
            shortcutHint(keys: "⎋", label: String(localized: "Close"))

            Spacer(minLength: 8)

            if !results.isEmpty {
                Text("\(results.count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func shortcutHint(keys: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: keys)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055))
                )

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Selection & Navigation

    private func syncSelectionWithResults() {
        guard !results.isEmpty else {
            selectedItemId = nil
            return
        }
        if let selectedItemId, results.contains(where: { $0.id == selectedItemId }) {
            return
        }
        selectedItemId = results[0].id
    }

    private func moveSelection(delta: Int) {
        guard !results.isEmpty else {
            return
        }
        let currentIndex = resolvedSelectedIndex ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), results.count - 1)
        selectedItemId = results[nextIndex].id
        keyboardScrollToken &+= 1
    }

    @discardableResult
    private func selectHighlightedItem() -> Bool {
        guard let item = resolvedSelectedItem else {
            return false
        }
        onSelect(item)
        return true
    }

    // MARK: - Formatting & Highlighting

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

    private static func highlightedText(
        _ source: String,
        matching query: String,
        fontSize: CGFloat,
        baseWeight: Font.Weight,
        baseColor: Color
    ) -> AttributedString {
        var attributed = AttributedString(source)
        attributed.font = .system(size: fontSize, weight: baseWeight)
        attributed.foregroundColor = baseColor

        guard !query.isEmpty else {
            return attributed
        }

        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source.range(
                  of: query,
                  options: .caseInsensitive,
                  range: searchStart..<source.endIndex
              ) {
            if let attrLower = AttributedString.Index(range.lowerBound, within: attributed),
               let attrUpper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[attrLower..<attrUpper].font = .system(size: fontSize, weight: .semibold)
                attributed[attrLower..<attrUpper].foregroundColor = LiquidGlassColors.sendButtonBlue
            }
            searchStart = range.upperBound
        }

        return attributed
    }
}

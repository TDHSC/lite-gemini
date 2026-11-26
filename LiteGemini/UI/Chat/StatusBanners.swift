import AppKit
import SwiftUI

// MARK: - NativeWelcomeView

/// Signed-out Liquid Glass gate displayed in Native Mode when no Google account is active.
/// Offers Google sign-in over the shared WebKit store alongside a one-click fallback to Classic Web Mode.
struct NativeWelcomeView: View {

    let onSignIn: () -> Void
    let onSwitchToWebMode: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            emblemView

            VStack(spacing: 8) {
                Text("Sign in to Gemini")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Sign in with your Google account to use Native Liquid Glass mode, or continue in Classic Web Mode.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LiquidGlassContainer(spacing: 10) {
                VStack(spacing: 10) {
                    Button(action: onSignIn) {
                        Text("Sign in with Google")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 22)
                    }
                    .controlSize(.large)
                    .liquidGlassButtonStyle(prominent: true, tint: LiquidGlassColors.sendButtonBlue)

                    Button(action: onSwitchToWebMode) {
                        Text("Switch to Classic Web Mode")
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 20)
                    }
                    .controlSize(.large)
                    .liquidGlassButtonStyle(prominent: false)
                }
            }
            .padding(.top, 2)
        }
        .environment(\.colorScheme, colorScheme)
        .padding(.horizontal, 26)
        .padding(.vertical, 28)
        .frame(maxWidth: 340)
        .glassCard(cornerRadius: 22, variant: .clear, tint: LiquidGlassColors.clearCardTint)
        .padding(.horizontal, 16)
    }

    private var emblemView: some View {
        MonochromeSparkShape()
            .fill(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.92),
                        Color.primary.opacity(0.48)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 24, height: 24)
            .glassOrb(size: 56, variant: .clear, interactive: false)
            .accessibilityHidden(true)
    }
}

// MARK: - ChallengeBannerView

/// Actionable warning banner surfaced when a mid-session auth challenge, CAPTCHA/policy prompt,
/// unexpected redirect, or bridge fallback interrupts the hidden session.
struct ChallengeBannerView: View {

    let banner: ChallengeBannerState
    let onVerifyInPopup: () -> Void
    let onSwitchToWebMode: () -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            compactLayout
        }
        .environment(\.colorScheme, colorScheme)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(
            cornerRadius: LiquidGlassMetrics.defaultCardCornerRadius,
            variant: .clear,
            tint: LiquidGlassColors.warningGlassTint
        )
    }

    // MARK: - Layouts

    private var wideLayout: some View {
        HStack(spacing: 10) {
            iconView
            messageText
            Spacer(minLength: 8)
            actionButtons
            dismissButton
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                iconView
                    .padding(.top, 1)
                messageText
                Spacer(minLength: 4)
                dismissButton
            }

            HStack(spacing: 8) {
                actionButtons
            }
        }
    }

    // MARK: - Subviews

    private var iconView: some View {
        Image(systemName: iconName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(LiquidGlassColors.warningAccent)
            .accessibilityHidden(true)
    }

    private var messageText: some View {
        Text(banner.message)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actionButtons: some View {
        LiquidGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onVerifyInPopup) {
                    Text("Verify in Popup")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.small)
                .liquidGlassButtonStyle(prominent: true, tint: LiquidGlassColors.sendButtonBlue)

                Button(action: onSwitchToWebMode) {
                    Text("Web Mode")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.small)
                .liquidGlassButtonStyle(prominent: false)
            }
        }
    }

    @ViewBuilder
    private var dismissButton: some View {
        if let onDismiss {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
    }

    private var iconName: String {
        switch banner.kind {
        case .reauthRequired:
            return "person.crop.circle.badge.exclamationmark"
        case .captchaOrPolicy:
            return "lock.shield.fill"
        case .unexpectedRedirect:
            return "exclamationmark.triangle.fill"
        case .bridgeFallback:
            return "bolt.horizontal.circle.fill"
        }
    }
}

// MARK: - DownloadToastView

/// Floating top Liquid Glass capsule toast for `DownloadNotice` with a "Show in Finder" action
/// and a 4-second auto-dismiss timer that pauses while the pointer hovers over the toast.
struct DownloadToastView: View {

    let notice: DownloadNotice
    var autoDismissDuration: Duration = .seconds(4)
    let onDismiss: () -> Void
    var onShowInFinder: ((URL) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveringToast = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(notice.isError ? LiquidGlassColors.warningAccent : Color.primary.opacity(0.78))
                .accessibilityHidden(true)

            Text(notice.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.90))
                .lineLimit(1)
                .truncationMode(.middle)

            if let fileURL = notice.fileURL {
                Button {
                    if let onShowInFinder {
                        onShowInFinder(fileURL)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                    onDismiss()
                } label: {
                    Text("Show in Finder")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.small)
                .liquidGlassButtonStyle(prominent: false)
                .layoutPriority(1)
            }
        }
        .environment(\.colorScheme, colorScheme)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCapsule(variant: .clear, tint: LiquidGlassColors.clearCardTint)
        .onHover { hovering in
            isHoveringToast = hovering
        }
        .task(id: notice.id) {
            var remaining = autoDismissDuration
            let tick: Duration = .milliseconds(100)
            while remaining > .zero {
                do {
                    try await Task.sleep(for: tick)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                if !isHoveringToast {
                    remaining -= tick
                }
            }
            guard !Task.isCancelled else {
                return
            }
            onDismiss()
        }
    }
}

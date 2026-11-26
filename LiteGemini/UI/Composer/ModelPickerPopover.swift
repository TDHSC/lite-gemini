import SwiftUI

// MARK: - ModelPickerPopover

/// Compact, intrinsically sized model switcher popover shared identically by Main Window
/// (`quickModeTempBinding == nil`) and Quick Mode (`quickModeTempBinding != nil`).
///
/// Uses `.fixedSize(horizontal: true, vertical: true)` bounded within `[168pt, 236pt]` so the
/// popover hugs its longest model title/subtitle with a tight trailing gap to the checkmark and
/// zero excess whitespace on the right.
struct ModelPickerPopover: View {

    // MARK: - Constants

    static let minPopoverWidth: CGFloat = 168
    static let maxPopoverWidth: CGFloat = 236

    // MARK: - Properties

    let models: [ModelOption]
    let selectedModelId: String?
    var isLoading: Bool = false
    var quickModeTempBinding: Binding<Bool>? = nil
    let onSelectModel: (ModelOption) -> Void
    let onDismiss: () -> Void

    @State private var hoveredModelId: String?
    @State private var isHoveringTempSwitch = false

    private var effectiveSelectedModelId: String? {
        if let selectedModelId, models.contains(where: { $0.id == selectedModelId }) {
            return selectedModelId
        }
        return models.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Divider()
                .opacity(0.5)

            if models.isEmpty {
                emptyStateRow
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(models) { model in
                        modelRow(for: model)
                    }
                }
                .padding(6)
            }
        }
        .frame(
            minWidth: Self.minPopoverWidth,
            maxWidth: Self.maxPopoverWidth,
            alignment: .leading
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Model")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 14)

            if let tempBinding = quickModeTempBinding {
                quickModeTempSwitch(binding: tempBinding)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, quickModeTempBinding != nil ? 4 : 8)
    }

    private func quickModeTempSwitch(binding: Binding<Bool>) -> some View {
        let isOn = binding.wrappedValue

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                binding.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                TemporaryChatGhostShape()
                    .fill(
                        isOn
                            ? LiquidGlassColors.tempActiveAccent
                            : Color.secondary.opacity(0.85),
                        style: FillStyle(eoFill: true)
                    )
                    .frame(width: 11, height: 11)

                Text("Temp")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? LiquidGlassColors.tempActiveAccent : Color.secondary)
                    .lineLimit(1)

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill(
                            isOn
                                ? LiquidGlassColors.tempActiveAccent
                                : Color.primary.opacity(0.18)
                        )
                        .frame(width: 22, height: 13)

                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0.5)
                        .frame(width: 9, height: 9)
                        .padding(2)
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 4)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isOn
                            ? LiquidGlassColors.tempActiveTint
                            : (isHoveringTempSwitch ? LiquidGlassColors.hoverHighlight : Color.primary.opacity(0.05))
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isOn
                            ? LiquidGlassColors.tempActiveAccent.opacity(0.32)
                            : Color.primary.opacity(0.08),
                        lineWidth: LiquidGlassMetrics.hairlineWidth
                    )
            )
            .frame(minHeight: 28)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringTempSwitch = hovering
            }
        }
        .help(isOn ? String(localized: "Temporary Chat: On") : String(localized: "Temporary Chat: Off"))
        .accessibilityLabel(Text("Temporary Chat"))
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }

    // MARK: - Model List

    private func modelRow(for model: ModelOption) -> some View {
        let isSelected = effectiveSelectedModelId == model.id
        let isHovered = hoveredModelId == model.id
        let trimmedSubtitle = model.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        return Button {
            onSelectModel(model)
            onDismiss()
        } label: {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(model.displayName)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.90))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtitle = trimmedSubtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 14)

                Group {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(rowBackgroundColor(isSelected: isSelected, isHovered: isHovered))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredModelId = hovering ? model.id : (hoveredModelId == model.id ? nil : hoveredModelId)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var emptyStateRow: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)

                Text("Loading models…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)

                Text("Default Model")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
    }

    private func rowBackgroundColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isHovered {
            return LiquidGlassColors.hoverHighlight
        }
        if isSelected {
            return LiquidGlassColors.sendButtonBlue.opacity(0.11)
        }
        return .clear
    }
}

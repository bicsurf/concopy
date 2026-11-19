import SwiftUI

struct PanelIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(isHovered ? ConCopyTheme.Rows.hoverBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
        .onHover { isHovered = $0 }
    }
}

struct PanelShortcutBadge: View {
    let text: String
    var modifier: String? = nil
    var isSelected = false

    var body: some View {
        HStack(spacing: 2) {
            if let modifier {
                Text(modifier)
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(ConCopyTheme.Badges.quickPasteForeground(isSelected: isSelected))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(ConCopyTheme.Badges.quickPasteBackground(isSelected: isSelected),
                    in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

struct ClipboardEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(ConCopyTheme.Accents.primary)
                .frame(width: 54, height: 54)
                .background(ConCopyTheme.Rows.selectedBackground, in: RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 280)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PanelNotice: View {
    let title: String
    var message: String? = nil
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(ConCopyTheme.Accents.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ConCopyTheme.Rows.selectedBackground.opacity(0.5))
    }
}

import AppKit
import ConCopyCore
import SwiftUI

public struct ClipRowView: View, Equatable {
    public let clip: ClipRecord
    public let index: Int
    public let isSelected: Bool
    public let isChecked: Bool
    public let isPasting: Bool
    public var isCopied: Bool = false
    public var actionTitle: String = "Copy"
    public let shortcutLabel: String?
    public var quickPasteModifier: String = "⌘"
    // Snapshot image identity on the UI actor so nonisolated equality only reads Sendable values.
    public var thumbnailImage: NSImage? = nil {
        didSet { thumbnailImageIdentity = thumbnailImage.map(ObjectIdentifier.init) }
    }
    private var thumbnailImageIdentity: ObjectIdentifier? = nil
    public var fileIconImage: NSImage? = nil {
        didSet { fileIconImageIdentity = fileIconImage.map(ObjectIdentifier.init) }
    }
    private var fileIconImageIdentity: ObjectIdentifier? = nil
    public var appIconImage: NSImage? = nil {
        didSet { appIconImageIdentity = appIconImage.map(ObjectIdentifier.init) }
    }
    private var appIconImageIdentity: ObjectIdentifier? = nil
    public var linkMetadata: WebLinkMetadata? = nil
    public var shouldMaskSensitive: Bool = false
    public let onToggleCheck: () -> Void
    public var onToggleFavorite: (() -> Void)? = nil
    public var onRowClick: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isRevealedLocally: Bool = false
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        clip: ClipRecord,
        index: Int,
        isSelected: Bool,
        isChecked: Bool,
        isPasting: Bool,
        isCopied: Bool = false,
        actionTitle: String = "Copy",
        shortcutLabel: String?,
        quickPasteModifier: String = "⌘",
        thumbnailImage: NSImage? = nil,
        fileIconImage: NSImage? = nil,
        appIconImage: NSImage? = nil,
        linkMetadata: WebLinkMetadata? = nil,
        shouldMaskSensitive: Bool = false,
        onToggleCheck: @escaping () -> Void,
        onToggleFavorite: (() -> Void)? = nil,
        onRowClick: (() -> Void)? = nil
    ) {
        self.clip = clip
        self.index = index
        self.isSelected = isSelected
        self.isChecked = isChecked
        self.isPasting = isPasting
        self.isCopied = isCopied
        self.actionTitle = actionTitle
        self.shortcutLabel = shortcutLabel
        self.quickPasteModifier = quickPasteModifier
        self.thumbnailImage = thumbnailImage
        self.thumbnailImageIdentity = thumbnailImage.map(ObjectIdentifier.init)
        self.fileIconImage = fileIconImage
        self.fileIconImageIdentity = fileIconImage.map(ObjectIdentifier.init)
        self.appIconImage = appIconImage
        self.appIconImageIdentity = appIconImage.map(ObjectIdentifier.init)
        self.linkMetadata = linkMetadata
        self.shouldMaskSensitive = shouldMaskSensitive
        self.onToggleCheck = onToggleCheck
        self.onToggleFavorite = onToggleFavorite
        self.onRowClick = onRowClick
    }

    public nonisolated static func == (lhs: ClipRowView, rhs: ClipRowView) -> Bool {
        lhs.clip == rhs.clip && lhs.index == rhs.index && lhs.isSelected == rhs.isSelected
            && lhs.isChecked == rhs.isChecked && lhs.isPasting == rhs.isPasting && lhs.isCopied == rhs.isCopied
            && lhs.actionTitle == rhs.actionTitle && lhs.shortcutLabel == rhs.shortcutLabel
            && lhs.quickPasteModifier == rhs.quickPasteModifier && lhs.thumbnailImageIdentity == rhs.thumbnailImageIdentity
            && lhs.fileIconImageIdentity == rhs.fileIconImageIdentity && lhs.appIconImageIdentity == rhs.appIconImageIdentity
            && lhs.linkMetadata == rhs.linkMetadata && lhs.shouldMaskSensitive == rhs.shouldMaskSensitive
    }

    private var accessibilityTitle: String {
        textPresentation.accessibilityTitle
    }

    private var displayPreviewText: String {
        textPresentation.preview
    }

    private var textPresentation: ClipRowTextPresentation {
        ClipRowTextPresentation(plainText: clip.plainText, fallbackTitle: clip.primaryType.rawValue,
            shouldMaskSensitive: shouldMaskSensitive, isRevealed: isRevealedLocally)
    }

    public var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isChecked ? ConCopyTheme.Accents.primary : Color.secondary)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isChecked ? "Deselect" : "Select") \(accessibilityTitle)")
            .accessibilityValue(isChecked ? "Selected" : "Not selected")
            .help("Select for batch actions")

            Button {
                onRowClick?()
            } label: {
                HStack(spacing: 10) {
                    // Type Icon Badge or Preview
                    if let thumb = thumbnailImage {
                        ZStack(alignment: .bottomTrailing) {
                            Image(nsImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                                )
                            if let appIcon = appIconImage {
                                Image(nsImage: appIcon)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: 12, height: 12)
                                    .offset(x: 2, y: 2)
                            }
                        }
                        .frame(width: 26, height: 26)
                    } else if let icon = fileIconImage {
                        ZStack(alignment: .bottomTrailing) {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                            if let appIcon = appIconImage {
                                Image(nsImage: appIcon)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: 11, height: 11)
                                    .offset(x: 2, y: 2)
                            }
                        }
                        .frame(width: 24, height: 24)
                    } else if let appIcon = appIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .shadow(color: Color.black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                    } else if let color = ColorParser.parse(clip.plainText ?? "") {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(color.swiftUIColor)
                                .frame(width: 24, height: 24)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                                .frame(width: 24, height: 24)
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(typeBadgeBackground)
                                .frame(width: 24, height: 24)
                            typeIcon
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(typeBadgeForeground)
                        }
                    }

                    if let meta = linkMetadata, let title = meta.title, !title.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(displayPreviewText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 6) {
                            if shouldMaskSensitive && !isRevealedLocally {
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ConCopyTheme.Accents.primary)
                                    .help("Sensitive content masked (Privacy Shield). Hover/click or QuickLook to reveal.")
                            }
                            Text(displayPreviewText)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isPasting {
                        ProgressView().controlSize(.mini)
                    } else if isCopied {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(ConCopyTheme.Accents.success)
                            .help("Copied to clipboard")
                    }
                    if let shortcutLabel {
                        PanelShortcutBadge(text: shortcutLabel, modifier: quickPasteModifier, isSelected: isSelected)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(actionTitle) \(accessibilityTitle)")
            .accessibilityValue(isCopied ? "Copied" : "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button {
                onToggleFavorite?()
            } label: {
                Image(systemName: clip.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(clip.isFavorite ? ConCopyTheme.Accents.star : Color.secondary)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(clip.isFavorite ? "Remove favorite" : "Favorite") \(accessibilityTitle)")
            .help(clip.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 6)
        .background(
            isChecked
                ? ConCopyTheme.Rows.batchSelectedBackground
                : (isSelected
                    ? ConCopyTheme.Rows.selectedBackground
                    : (isHovered ? ConCopyTheme.Rows.hoverBackground : Color.clear)),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    (isSelected || isChecked)
                        ? (contrast == .increased ? Color.primary : ConCopyTheme.Rows.selectedBorder) : Color.clear,
                    lineWidth: contrast == .increased ? 2 : 1)
        }
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
    }

    private var typeBadgeBackground: Color {
        ConCopyTheme.Types.background(for: clip.primaryType)
    }

    private var typeBadgeForeground: Color {
        ConCopyTheme.Types.foreground(for: clip.primaryType)
    }

    @ViewBuilder
    private var typeIcon: some View {
        switch clip.primaryType {
        case .text:
            Image(systemName: "text.alignleft")
        case .richText:
            Image(systemName: "doc.richtext")
        case .html:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        case .image:
            Image(systemName: "photo")
        case .file:
            Image(systemName: "doc")
        case .url:
            Image(systemName: "link")
        case .color:
            Image(systemName: "paintpalette")
        }
    }
}

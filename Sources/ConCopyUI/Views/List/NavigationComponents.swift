import AppKit
import ConCopyCore
import SwiftUI

public struct WindowDragGestureArea: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    public func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

public final class WindowDragNSView: NSView {
    public override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material = .hudWindow
    public var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    public var state: NSVisualEffectView.State = .active

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material { nsView.material = material }
        if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
        if nsView.state != state { nsView.state = state }
    }
}

public struct TypeFilterPill: View {
    public let filter: ClipTypeFilter
    public let isSelected: Bool
    public let action: () -> Void

    public init(filter: ClipTypeFilter, isSelected: Bool, action: @escaping () -> Void) {
        self.filter = filter
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: filter.icon)
                    .font(.system(size: 9))
                Text(filter.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(isSelected ? ConCopyTheme.Accents.primary : Color.secondary)
            .background(
                isSelected ? ConCopyTheme.Rows.selectedBackground : ConCopyTheme.Surfaces.pillBackground,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? ConCopyTheme.Rows.selectedBorder : ConCopyTheme.Surfaces.pillBorder, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

public struct ListTabButton: View {
    public let title: String
    public let icon: String
    public let isSelected: Bool
    public var shortcutHint: String? = nil
    public let action: () -> Void

    public init(
        title: String,
        icon: String,
        isSelected: Bool,
        shortcutHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.shortcutHint = shortcutHint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                tabLabel(showShortcut: true)
                tabLabel(showShortcut: false)
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .foregroundStyle(isSelected ? ConCopyTheme.Accents.primary : Color.primary)
            .background(
                isSelected ? ConCopyTheme.Rows.selectedBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(shortcutHint.map { "\(title) (\($0))" } ?? title)
    }

    private func tabLabel(showShortcut: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(title).fixedSize()
            if showShortcut, let shortcutHint {
                Text(shortcutHint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
    }
}

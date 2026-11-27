import AppKit
import ConCopyCore
import SwiftUI

public struct MoveToListSheetView: View {
    @ObservedObject public var viewModel: ClipboardViewModel
    @ObservedObject private var shortcutsManager = GlobalShortcutsManager.shared
    public let clip: ClipRecord
    @State private var eventMonitor: Any? = nil

    public init(viewModel: ClipboardViewModel, clip: ClipRecord) {
        self.viewModel = viewModel
        self.clip = clip
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundColor(ConCopyTheme.Accents.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move to List")
                        .font(.headline)
                    Text(
                        "Select by clicking, \(shortcutsManager.listModifierSymbol)A or \(shortcutsManager.listModifierSymbol)1..9"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            Divider().opacity(0.3)

            VStack(spacing: 6) {
                // Fixed option "No List (All)"
                Button(action: {
                    viewModel.assignMovingClipToAll()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .frame(width: 16)
                        Text("No List (All)")
                            .font(.system(size: 13, weight: clip.listId == nil ? .semibold : .regular))
                        Spacer()
                        PanelShortcutBadge(
                            text: "A",
                            modifier: shortcutsManager.listModifierSymbol,
                            isSelected: clip.listId == nil
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        clip.listId == nil
                            ? ConCopyTheme.Rows.selectedBackground
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)

                // Option 1: Favorites
                Button(action: {
                    viewModel.assignMovingClip(toOptionIndex: 1)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: clip.isFavorite ? "star.slash" : "star.fill")
                            .frame(width: 16)
                            .foregroundColor(ConCopyTheme.Accents.star)
                        Text(clip.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                            .font(.system(size: 13))
                        Spacer()
                        PanelShortcutBadge(
                            text: "1",
                            modifier: shortcutsManager.listModifierSymbol,
                            isSelected: clip.isFavorite
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        clip.isFavorite
                            ? ConCopyTheme.Rows.selectedBackground
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)

                // Option 2: Convert to Snippet
                Button(action: {
                    viewModel.assignMovingClip(toOptionIndex: 2)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "curlybraces")
                            .frame(width: 16)
                            .foregroundColor(ConCopyTheme.Accents.primary)
                        Text("Convert to Snippet...")
                            .font(.system(size: 13))
                        Spacer()
                        PanelShortcutBadge(
                            text: "2",
                            modifier: shortcutsManager.listModifierSymbol,
                            isSelected: false
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                // User custom lists (up to 7 lists to fit digits 3..9)
                ForEach(Array(viewModel.lists.prefix(7).enumerated()), id: \.element.id) { index, list in
                    let digit = index + 3
                    Button(action: {
                        viewModel.assignMovingClip(toOptionIndex: digit)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .frame(width: 16)
                            Text(list.name)
                                .font(.system(size: 13, weight: clip.listId == list.id ? .semibold : .regular))
                            Spacer()
                            PanelShortcutBadge(
                                text: "\(digit)",
                                modifier: shortcutsManager.listModifierSymbol,
                                isSelected: clip.listId == list.id
                            )
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            clip.listId == list.id
                                ? ConCopyTheme.Rows.selectedBackground
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().opacity(0.3)

            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.movingClip = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let keyMod = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let expectedMod = shortcutsManager.listModifierFlags

                if event.keyCode == 53 { // ESC
                    viewModel.movingClip = nil
                    return nil
                }

                if keyMod == expectedMod {
                    if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "a" {
                        viewModel.assignMovingClipToAll()
                        return nil
                    }

                    if let digit = GlobalShortcutsManager.digitIndex(forKeyCode: event.keyCode) {
                        viewModel.assignMovingClip(toOptionIndex: digit)
                        return nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }
}

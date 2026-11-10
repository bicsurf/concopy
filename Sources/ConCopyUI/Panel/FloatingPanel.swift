import AppKit
import ConCopyCore
import SwiftUI

public final class FloatingPanel: NSPanel {
    public let viewModel: ClipboardViewModel

    public init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.becomesKeyOnlyIfNeeded = true
        self.isMovableByWindowBackground = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        viewModel.onClosePanel = { [weak self] in
            self?.orderOut(nil)
        }

        self.contentView = NSHostingView(rootView: ClipboardListView(viewModel: viewModel))
    }

    public convenience init(databaseManager: DatabaseManager) {
        let vm = ClipboardViewModel(databaseManager: databaseManager)
        self.init(viewModel: vm)
    }

    public convenience init() {
        let db = DatabaseManager.makeFallback()
        self.init(databaseManager: db)
    }

    public override var canBecomeKey: Bool {
        true
    }

    public override var canBecomeMain: Bool {
        false
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if handleKeyDown(event) {
                return
            }
        }
        super.sendEvent(event)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Escape: close preview/modals, clear search, or close panel
        if event.keyCode == 53 {
            if viewModel.isQuickLookVisible {
                viewModel.isQuickLookVisible = false
                return true
            }
            if viewModel.editingClip != nil {
                viewModel.editingClip = nil
                return true
            }
            if viewModel.renamingClip != nil {
                viewModel.renamingClip = nil
                return true
            }
            if !viewModel.searchQuery.isEmpty {
                viewModel.searchQuery = ""
                return true
            } else {
                orderOut(nil)
                return true
            }
        }

        // Spacebar: toggle QuickLook preview when not searching
        if event.keyCode == 49 && !viewModel.isSearchFocused {
            viewModel.toggleQuickLook()
            return true
        }

        // Left Arrow (123): open QuickLook
        if event.keyCode == 123 && !viewModel.isSearchFocused {
            viewModel.isQuickLookVisible = true
            return true
        }

        // Right Arrow (124): close QuickLook
        if event.keyCode == 124 && !viewModel.isSearchFocused && viewModel.isQuickLookVisible {
            viewModel.isQuickLookVisible = false
            return true
        }

        // Cmd+,: Open preferences
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "," {
            PreferencesWindowController.shared.showWindow()
            return true
        }

        // Cmd+F: focus search field
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            viewModel.isSearchFocused = true
            return false // Let it propagate to focus the field
        }

        // Return / Enter: paste selected
        if event.keyCode == 36 {
            let optionHeld = event.modifierFlags.contains(.option)
            viewModel.pasteSelected(optionHeld: optionHeld)
            return true
        }

        // Up arrow: move selection up (Shift expands selection)
        if event.keyCode == 126 {
            let shiftHeld = event.modifierFlags.contains(.shift)
            viewModel.moveSelectionUp(expandSelection: shiftHeld)
            return true
        }

        // Down arrow: move selection down (Shift expands selection)
        if event.keyCode == 125 {
            let shiftHeld = event.modifierFlags.contains(.shift)
            viewModel.moveSelectionDown(expandSelection: shiftHeld)
            return true
        }

        // Quick paste with 0-9 and a-z when search is not actively focused
        if !viewModel.isSearchFocused {
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                if let char = event.charactersIgnoringModifiers,
                   let index = QuickPasteShortcutMapper.index(forCharacter: char) {
                    let optionHeld = event.modifierFlags.contains(.option)
                    viewModel.paste(at: index, optionHeld: optionHeld)
                    return true
                }
            }
        }

        return false
    }

    public func togglePanel() {
        if isVisible {
            orderOut(nil)
        } else {
            viewModel.loadClips()
            positionNearMouse()
            orderFrontRegardless()
        }
    }

    public func positionNearMouse() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelSize = frame.size

        var originX = mouseLocation.x - (panelSize.width / 2)
        var originY = mouseLocation.y - panelSize.height - 10

        originX = max(screenFrame.minX + 8, min(originX, screenFrame.maxX - panelSize.width - 8))
        if originY < screenFrame.minY + 8 {
            originY = mouseLocation.y + 10
        }
        originY = max(screenFrame.minY + 8, min(originY, screenFrame.maxY - panelSize.height - 8))

        setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

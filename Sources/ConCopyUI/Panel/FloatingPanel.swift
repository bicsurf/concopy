import AppKit
import ConCopyCore
import SwiftUI

public final class FloatingPanel: NSPanel {
    public let viewModel: ClipboardViewModel
    public private(set) var previousActiveApp: NSRunningApplication?
    public var previousApp: NSRunningApplication? {
        previousActiveApp
    }
    public var onOpenSettings: (() -> Void)?

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
        self.becomesKeyOnlyIfNeeded = false
        self.isMovableByWindowBackground = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.initialFirstResponder = nil
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.setFrameAutosaveName("ConCopyFloatingPanelFrame")

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.previousActiveApp = frontApp
        }

        viewModel.onClosePanel = { [weak self] in
            self?.hidePanel(restoreFocus: true)
        }

        self.contentView = NSHostingView(rootView: ClipboardListView(viewModel: viewModel))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceDidActivateApp(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    public func hidePanel(restoreFocus: Bool = true) {
        orderOut(nil)
        if restoreFocus {
            if let targetApp = previousActiveApp, !targetApp.isTerminated {
                if #available(macOS 14.0, *) {
                    targetApp.activate()
                } else {
                    targetApp.activate(options: [.activateIgnoringOtherApps])
                }
            } else {
                NSApp.hide(nil)
            }
        }
    }

    public override func resignKey() {
        super.resignKey()
        if isVisible && attachedSheet == nil {
            hidePanel(restoreFocus: false)
        }
    }

    @objc private func handleWindowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self else { return }
        if isVisible && attachedSheet == nil {
            hidePanel(restoreFocus: false)
        }
    }

    @objc private func handleAppResignActive() {
        if isVisible && attachedSheet == nil {
            hidePanel(restoreFocus: false)
        }
    }

    @objc private func handleWorkspaceDidActivateApp(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.previousActiveApp = app
            if isVisible && attachedSheet == nil {
                hidePanel(restoreFocus: false)
            }
        }
    }

    public override func orderOut(_ sender: Any?) {
        saveFrame(usingName: "ConCopyFloatingPanelFrame")
        viewModel.isSearchFocused = false
        super.orderOut(sender)
    }

    public override func mouseDragged(with event: NSEvent) {
        if isMovableByWindowBackground {
            performDrag(with: event)
        } else {
            super.mouseDragged(with: event)
        }
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

    public func activatePanelForInput() {
        makeKey()
        NSApp.activate()
    }

    public override func cancelOperation(_ sender: Any?) {
        if viewModel.isQuickLookVisible {
            viewModel.isQuickLookVisible = false
            return
        }
        if viewModel.editingClip != nil {
            viewModel.editingClip = nil
            return
        }
        if viewModel.renamingClip != nil {
            viewModel.renamingClip = nil
            return
        }
        if viewModel.movingClip != nil {
            viewModel.movingClip = nil
            return
        }
        if !viewModel.selectedClipIds.isEmpty {
            viewModel.clearSelection()
            return
        }
        if !viewModel.searchQuery.isEmpty {
            viewModel.searchQuery = ""
            return
        }
        hidePanel(restoreFocus: true)
    }

    public override func sendEvent(_ event: NSEvent) {
        if attachedSheet != nil {
            if event.type == .keyDown && handleSheetKeyDown(event) {
                return
            }
            super.sendEvent(event)
            return
        }
        if event.type == .keyDown {
            if handleKeyDown(event) {
                return
            }
        }
        super.sendEvent(event)
    }

    private func handleSheetKeyDown(_ event: NSEvent) -> Bool {
        if viewModel.movingClip != nil {
            if event.keyCode == 53 {
                viewModel.movingClip = nil
                return true
            }
            if let digit = GlobalShortcutsManager.shared.matchedListDigit(for: event) {
                viewModel.assignMovingClip(toOptionIndex: digit)
                return true
            }
        }
        return false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Escape: close preview/modals, clear selection, clear search, or close panel
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
            if viewModel.movingClip != nil {
                viewModel.movingClip = nil
                return true
            }
            if !viewModel.selectedClipIds.isEmpty {
                viewModel.clearSelection()
                return true
            }
            if !viewModel.searchQuery.isEmpty {
                viewModel.searchQuery = ""
                return true
            } else {
                hidePanel(restoreFocus: true)
                return true
            }
        }

        // Spacebar: toggle QuickLook preview when query is empty or search is not focused
        if event.keyCode == 49 && (!viewModel.isSearchFocused || viewModel.searchQuery.isEmpty) {
            viewModel.toggleQuickLook()
            return true
        }

        // Left Arrow (123): open QuickLook (allowed if query is empty or not in search)
        if event.keyCode == 123 && (!viewModel.isSearchFocused || viewModel.searchQuery.isEmpty) {
            viewModel.isQuickLookVisible = true
            return true
        }

        // Right Arrow (124): close QuickLook
        if event.keyCode == 124 && viewModel.isQuickLookVisible {
            viewModel.isQuickLookVisible = false
            return true
        }

        // Configurable shortcut: Open preferences
        if GlobalShortcutsManager.shared.matches(event: event, for: .openPreferences) {
            hidePanel(restoreFocus: false)
            if let onOpenSettings = self.onOpenSettings {
                onOpenSettings()
            } else if let onOpenSettings = viewModel.onOpenSettings {
                onOpenSettings()
            } else {
                PreferencesWindowController.shared.showWindow()
            }
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        // Configurable shortcut: Focus search field
        if GlobalShortcutsManager.shared.matches(event: event, for: .focusSearch) {
            viewModel.isSearchFocused = true
            return false // Let it propagate to focus the field
        }

        // Configurable shortcut: Paste selected clip
        if GlobalShortcutsManager.shared.matches(event: event, for: .pasteSelection) {
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

        // Configurable shortcut: Clear selection if multi-selection active, else toggle favorite
        if GlobalShortcutsManager.shared.matches(event: event, for: .toggleFavorite) {
            if !viewModel.selectedClipIds.isEmpty {
                viewModel.clearSelection()
            } else {
                viewModel.toggleFavoriteSelected()
            }
            return true
        }

        // Configurable shortcut: Move selected clip to list or snippet
        if GlobalShortcutsManager.shared.matches(event: event, for: .moveToList) {
            viewModel.promptMoveSelectedClipToList()
            return true
        }

        // Configurable shortcut: Copy selected clip or batch to clipboard
        if GlobalShortcutsManager.shared.matches(event: event, for: .copySelection) {
            let hasTextSelectionInField: Bool = {
                if let textEditor = firstResponder as? NSText {
                    return textEditor.selectedRange.length > 0
                }
                return false
            }()

            if !hasTextSelectionInField {
                viewModel.copySelectedToPasteboard()
                return true
            }
        }

        // Numeric shortcuts: List / Tab Selection (Default Cmd + 1..9, or Option + 1..9 if swapped)
        if let digit = GlobalShortcutsManager.shared.matchedListDigit(for: event) {
            if digit == 1 {
                viewModel.selectAllClips()
                return true
            } else if digit == 2 {
                viewModel.selectFavorites()
                return true
            } else if digit == 3 {
                viewModel.selectSnippets()
                return true
            } else {
                let listIndex = digit - 4
                if listIndex >= 0 && listIndex < viewModel.lists.count {
                    let list = viewModel.lists[listIndex]
                    viewModel.selectList(list.id)
                    return true
                }
            }
        }

        // Numeric shortcuts: Quick Paste Record (Default Option + 1..9, 0, or Cmd + 1..9, 0 if swapped)
        if let index = GlobalShortcutsManager.shared.matchedQuickPasteIndex(for: event) {
            let optionHeld = event.modifierFlags.contains(.option)
            if viewModel.isSnippetsOnly {
                let list = viewModel.filteredSnippets
                if index >= 0 && index < list.count {
                    viewModel.selectedSnippetIndex = index
                    viewModel.pasteSnippet(list[index])
                    return true
                }
            } else {
                viewModel.paste(at: index, optionHeld: optionHeld)
                return true
            }
        }

        // Letters a-z quick paste fallback (when search is not actively focused), excluding reserved shortcuts (c, d, m, f)
        if !viewModel.isSearchFocused,
           event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.control),
           let char = event.charactersIgnoringModifiers?.lowercased().first,
           char >= "a" && char <= "z",
           char != "c" && char != "d" && char != "m" && char != "f" {
            let targetIndex = QuickPasteShortcutMapper.index(forCharacter: String(char))
            if let index = targetIndex {
                let optionHeld = event.modifierFlags.contains(.option)
                if viewModel.isSnippetsOnly {
                    let list = viewModel.filteredSnippets
                    if index >= 0 && index < list.count {
                        viewModel.selectedSnippetIndex = index
                        viewModel.pasteSnippet(list[index])
                        return true
                    }
                } else {
                    viewModel.paste(at: index, optionHeld: optionHeld)
                    return true
                }
            }
        }

        return false
    }

    private func digitIndex(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18, 83: return 0 // 1 or numpad 1
        case 19, 84: return 1 // 2 or numpad 2
        case 20, 85: return 2 // 3 or numpad 3
        case 21, 86: return 3 // 4 or numpad 4
        case 23, 87: return 4 // 5 or numpad 5
        case 22, 88: return 5 // 6 or numpad 6
        case 26, 89: return 6 // 7 or numpad 7
        case 28, 91: return 7 // 8 or numpad 8
        case 25, 92: return 8 // 9 or numpad 9
        case 29, 82: return 9 // 0 or numpad 0
        default: return nil
        }
    }

    public func showPanel() {
        if !isVisible {
            togglePanel()
        }
    }

    public func togglePanel() {
        if isVisible {
            hidePanel(restoreFocus: true)
        } else {
            let frontApp = NSWorkspace.shared.frontmostApplication
            if let frontApp, frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousActiveApp = frontApp
            }
            viewModel.prepareForPanelOpen()
            positionNearMouse()
            orderFrontRegardless()
            makeKeyAndOrderFront(nil)
            NSApp.activate()
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.isSearchFocused = true
            }
        }
    }

    public func positionNearMouse() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelSize = frame.size

        var originX = mouseLocation.x - (panelSize.width / 2)
        var originY = mouseLocation.y - panelSize.height - 12

        originX = max(screenFrame.minX + 8, min(originX, screenFrame.maxX - panelSize.width - 8))
        if originY < screenFrame.minY + 8 {
            originY = mouseLocation.y + 12
        }
        originY = max(screenFrame.minY + 8, min(originY, screenFrame.maxY - panelSize.height - 8))

        setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

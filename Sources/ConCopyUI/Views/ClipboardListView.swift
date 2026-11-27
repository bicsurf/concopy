import AppKit
import ConCopyCore
import SwiftUI

public struct ClipboardListView: View {
    @ObservedObject public var viewModel: ClipboardViewModel
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var shortcutsManager = GlobalShortcutsManager.shared
    @FocusState private var isFieldFocused: Bool
    @State private var editTextValue: String = ""
    @ObservedObject private var settings: AppSettingsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.appSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            panelHeader

            if viewModel.isHistoryTemporary {
                PanelNotice(
                    title: "Temporary history",
                    message: "Your saved history could not be opened. New clips are temporary; cleanup and iCloud sync are paused. Export a backup from Settings before quitting.",
                    systemImage: "exclamationmark.triangle", actionTitle: "Settings"
                ) { viewModel.onOpenSettings?() }
            }

            // Update Available Banner
            if let update = updateChecker.availableUpdate {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(ConCopyTheme.Accents.primary)
                        .font(.system(size: 13))

                    Text("New version v\(update.version) available")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)

                    Spacer()

                    Button("Download") {
                        UpdateDownloadController.shared.start(update)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button(action: {
                        updateChecker.skipUpdate(version: update.version)
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss for this version")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(ConCopyTheme.Badges.tabShortcutBackground(isSelected: true))
            }

            if settings.iCloudSyncEnabled && viewModel.cloudSyncStatus == .error {
                PanelNotice(
                    title: "iCloud sync needs attention",
                    message: "Sync could not be completed. Retry to recover available data from iCloud, or restore a backup in Settings.",
                    systemImage: "exclamationmark.icloud", actionTitle: "Retry"
                ) { viewModel.onRetrySync?() }
            }

            if !viewModel.isAccessibilityTrusted {
                PanelNotice(
                    title: "Copying is available",
                    message: "Allow Accessibility to paste directly into other apps.",
                    systemImage: "hand.raised",
                    actionTitle: "Allow paste",
                    action: viewModel.openAccessibilitySettings
                )
            }

            if settings.isMonitoringPaused {
                PanelNotice(
                    title: "Clipboard history is paused",
                    message: "Your saved clips are still available.",
                    systemImage: "pause.circle",
                    actionTitle: "Resume"
                ) {
                    settings.isMonitoringPaused = false
                }
            }

            Divider().opacity(0.3)

            scopeNavigation

            Divider().opacity(0.3)

            // Main Content: Snippets or Clips
            if viewModel.isSnippetsOnly {
                SnippetsListView(viewModel: viewModel, isFieldFocused: $isFieldFocused)
            } else if viewModel.clips.isEmpty {
                emptyClipsView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(viewModel.clips.enumerated()), id: \.element.id) { index, clip in
                                let shortcut = shortcutsManager.quickPasteShortcut(for: index, searchFocused: viewModel.isSearchFocused)
                                ClipRowView(
                                    clip: clip,
                                    index: index,
                                    isSelected: viewModel.selectedIndex == index,
                                    isChecked: viewModel.selectedClipIds.contains(clip.id),
                                    isPasting: viewModel.pastingClipId == clip.id,
                                    isCopied: viewModel.copiedClipId == clip.id,
                                    actionTitle: settings.isDirectPasteEnabled ? "Paste" : "Copy",
                                    shortcutLabel: shortcut?.label,
                                    quickPasteModifier: shortcut?.modifierSymbol ?? shortcutsManager.quickPasteModifierSymbol,
                                    thumbnailImage: clip.primaryType == .image
                                        ? viewModel.imageThumbnail(for: clip) : nil,
                                    fileIconImage: clip.primaryType == .file ? viewModel.fileIcon(for: clip) : nil,
                                    appIconImage: viewModel.appIcon(for: clip),
                                    linkMetadata: clip.primaryType == .url ? viewModel.linkMetadata(for: clip) : nil,
                                    shouldMaskSensitive: settings.maskSensitiveData && SensitiveDataDetector.isSensitive(clip.plainText),
                                    onToggleCheck: {
                                        viewModel.toggleSelection(clipId: clip.id)
                                    },
                                    onToggleFavorite: {
                                        viewModel.toggleFavorite(clip: clip)
                                    },
                                    onRowClick: {
                                        viewModel.handleRowClick(clip: clip, modifiers: NSEvent.modifierFlags)
                                    }
                                )
                                .equatable()
                                .id(clip.id)
                                .contextMenu {
                                    ClipContextMenu(viewModel: viewModel, clip: clip)
                                }
                            }
                            if viewModel.hasMoreClips {
                                Button("Load more clips") { viewModel.loadNextPage() }
                                    .disabled(viewModel.isLoadingClips)
                                    .padding(12)
                                    .onAppear { viewModel.loadNextPage() }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear {
                        viewModel.selectMostRecentClip()
                        if let firstId = viewModel.clips.first?.id {
                            proxy.scrollTo(firstId, anchor: .top)
                        }
                    }
                    .onChange(of: viewModel.scrollTargetTopTrigger) { _, _ in
                        if let firstId = viewModel.clips.first?.id {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(firstId, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: viewModel.selectedIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < viewModel.clips.count {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(viewModel.clips[newIndex].id, anchor: newIndex == 0 ? .top : .center)
                            }
                        }
                    }
                }
            }

            Divider().opacity(0.3)
            if !viewModel.selectedClipIds.isEmpty {
                ClipBatchBarView(viewModel: viewModel, settings: settings)
            } else {
                statusFooter
            }
        }
        .tint(ConCopyTheme.Accents.primary)
        .transaction { transaction in
            if reduceMotion { transaction.disablesAnimations = true }
        }
        .frame(minWidth: 360, minHeight: 480)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                ConCopyTheme.Surfaces.windowBackgroundTint
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ConCopyTheme.Surfaces.windowBorder, lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.async {
                isFieldFocused = true
                viewModel.isSearchFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let panel = notification.object as? FloatingPanel,
                panel.viewModel === viewModel
            else { return }
            DispatchQueue.main.async {
                guard panel.isKeyWindow, panel.attachedSheet == nil else { return }
                isFieldFocused = true
                viewModel.isSearchFocused = true
            }
        }
        .onChange(of: viewModel.isSearchFocused) { _, focused in
            if isFieldFocused != focused {
                isFieldFocused = focused
            }
        }
        // QuickLook Popover
        .sheet(isPresented: $viewModel.isQuickLookVisible) {
            if viewModel.selectedIndex >= 0 && viewModel.selectedIndex < viewModel.clips.count {
                let currentClip = viewModel.clips[viewModel.selectedIndex]
                QuickLookPopoverView(
                    clip: currentClip,
                    databaseManager: viewModel.databaseManager,
                    onPrevious: {
                        viewModel.moveSelectionUp()
                    },
                    onNext: {
                        viewModel.moveSelectionDown()
                    },
                    onClose: {
                        viewModel.isQuickLookVisible = false
                    }
                )
                .id(currentClip.id)
            }
        }
        // In-place text editor sheet
        .sheet(item: $viewModel.editingClip) { clip in
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit Text")
                    .font(.headline)
                TextEditor(text: $editTextValue)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 380, minHeight: 200)
                    .padding(4)
                    .border(Color.secondary.opacity(0.2))

                HStack {
                    Spacer()
                    Button("Cancel") {
                        viewModel.editingClip = nil
                    }
                    Button("Save") {
                        viewModel.saveEditedText(for: clip.id, newText: editTextValue)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .onAppear {
                editTextValue = clip.plainText ?? ""
            }
        }
        // Move to List sheet
        .sheet(item: $viewModel.movingClip) { clip in
            MoveToListSheetView(viewModel: viewModel, clip: clip)
        }
        // Snippet Editor sheet
        .sheet(isPresented: $viewModel.isSnippetEditorPresented) {
            SnippetEditorSheetView(
                snippet: viewModel.editingSnippet,
                errorMessage: viewModel.snippetSaveError,
                onSave: { shortcut, content, title in
                    Task {
                        let saved = await viewModel.saveSnippet(
                            shortcut: shortcut,
                            content: content,
                            title: title,
                            existingId: viewModel.editingSnippet?.id
                        )
                        if saved {
                            viewModel.isSnippetEditorPresented = false
                            viewModel.editingSnippet = nil
                        }
                    }
                },
                onCancel: {
                    viewModel.isSnippetEditorPresented = false
                    viewModel.editingSnippet = nil
                }
            )
        }
        // Snippet Variables Fill Sheet
        .sheet(item: $viewModel.promptSnippet) { snippet in
            SnippetVariablesPromptSheetView(
                snippet: snippet,
                variableNames: viewModel.promptSnippetVariables,
                onFill: { values in
                    viewModel.pasteSnippetWithVariables(snippet, values: values)
                },
                onCancel: {
                    viewModel.promptSnippet = nil
                    viewModel.promptSnippetVariables = []
                }
            )
        }
    }

    private var scopeName: String {
        if viewModel.isSnippetsOnly { return "Snippets" }
        if viewModel.isFavoritesOnly { return "Favorites" }
        if let id = viewModel.selectedListId,
            let list = viewModel.lists.first(where: { $0.id == id })
        {
            return list.name
        }
        return "All clips"
    }

    private var itemCount: Int {
        viewModel.isSnippetsOnly ? viewModel.filteredSnippets.count : viewModel.clips.count
    }

    private var panelHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(ConCopyTheme.Accents.primary)
                    .accessibilityHidden(true)
                Text("ConCopy")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                Text(
                    viewModel.isSnippetsOnly
                        ? "Select, then paste" : (settings.isDirectPasteEnabled ? "Paste on click" : "Copy on click")
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .help(
                    settings.isDirectPasteEnabled
                        ? "Click a clip to paste it into the active app. Change this in Settings."
                        : "Click a clip to copy it and close this panel. Change this in Settings.")
                Menu {
                    ForEach(ClipSortMode.allCases, id: \.self) { mode in
                        Button {
                            viewModel.currentSortMode = mode
                            viewModel.loadClips()
                        } label: {
                            if viewModel.currentSortMode == mode {
                                Label(mode.displayName, systemImage: "checkmark")
                            } else {
                                Text(mode.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(viewModel.isSnippetsOnly)
                .accessibilityLabel("Sort clips")
                .help("Sort: \(viewModel.currentSortMode.displayName)")

                if !viewModel.pasteQueue.isEmpty {
                    Menu {
                        Section("Paste Mode") {
                            Button {
                                viewModel.pasteQueueOrder = .fifo
                            } label: {
                                if viewModel.pasteQueueOrder == .fifo {
                                    Label("Queue (FIFO - First in First out)", systemImage: "checkmark")
                                } else {
                                    Text("Queue (FIFO - First in First out)")
                                }
                            }
                            Button {
                                viewModel.pasteQueueOrder = .lifo
                            } label: {
                                if viewModel.pasteQueueOrder == .lifo {
                                    Label("Stack (LIFO - Last in First out)", systemImage: "checkmark")
                                } else {
                                    Text("Stack (LIFO - Last in First out)")
                                }
                            }
                        }
                        Divider()
                        Button("Paste Next Item (⌃⌘V)") {
                            viewModel.pasteNextFromQueue()
                        }
                        Button("Clear Queue (\(viewModel.pasteQueue.count))", role: .destructive) {
                            viewModel.clearPasteQueue()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "rectangle.stack.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(viewModel.pasteQueue.count)")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(ConCopyTheme.Accents.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ConCopyTheme.Accents.primary.opacity(0.15), in: Capsule())
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Paste \(viewModel.pasteQueueOrder == .fifo ? "Queue" : "Stack"): \(viewModel.pasteQueue.count) item(s). Shortcut: ⌃⌘V")
                }

                PanelIconButton(title: "Settings", systemImage: "gearshape") {
                    if let action = viewModel.onOpenSettings {
                        action()
                    } else {
                        PreferencesWindowController.shared.showWindow()
                    }
                }
            }
            .background(WindowDragGestureArea())

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search \(scopeName.lowercased())…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFieldFocused)
                    .accessibilityLabel("Search \(scopeName)")
                    .onChange(of: isFieldFocused) { _, focused in
                        viewModel.isSearchFocused = focused
                    }
                    .onSubmit { viewModel.pasteSelected() }
                if !viewModel.searchQuery.isEmpty {
                    PanelIconButton(title: "Clear search", systemImage: "xmark.circle.fill") {
                        viewModel.searchQuery = ""
                        isFieldFocused = true
                    }
                } else if let shortcut = shortcutsManager.shortcut(for: .focusSearch) {
                    PanelShortcutBadge(text: shortcut.description)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 36)
            .background(ConCopyTheme.Surfaces.searchBackground, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isFieldFocused ? ConCopyTheme.Rows.selectedBorder : ConCopyTheme.Surfaces.pillBorder,
                        lineWidth: 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var scopeNavigation: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ListTabButton(
                    title: "All", icon: "tray.full",
                    isSelected: viewModel.selectedListId == nil && !viewModel.isFavoritesOnly
                        && !viewModel.isSnippetsOnly, shortcutHint: "\(shortcutsManager.listModifierSymbol)A"
                ) {
                    viewModel.selectAllClips()
                }
                ListTabButton(
                    title: "Favorites", icon: "star", isSelected: viewModel.isFavoritesOnly,
                    shortcutHint: "\(shortcutsManager.listModifierSymbol)1"
                ) {
                    viewModel.selectFavorites()
                }
                ListTabButton(
                    title: "Snippets", icon: "curlybraces", isSelected: viewModel.isSnippetsOnly,
                    shortcutHint: "\(shortcutsManager.listModifierSymbol)2"
                ) {
                    viewModel.selectSnippets()
                }
                PanelIconButton(title: "Create a list", systemImage: "plus", action: promptCreateNewList)
            }
            if !viewModel.lists.isEmpty {
                HStack(spacing: 8) {
                    Text("Lists")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(viewModel.lists.enumerated()), id: \.element.id) { index, list in
                                let digit = index + 3
                                ListTabButton(
                                    title: list.name,
                                    icon: list.isAutoStarActive ? "star.circle.fill" : "folder",
                                    isSelected: viewModel.selectedListId == list.id && !viewModel.isSnippetsOnly,
                                    shortcutHint: digit <= 10
                                        ? "\(shortcutsManager.listModifierSymbol)\(digit == 10 ? 0 : digit)" : nil
                                ) {
                                    viewModel.selectList(list.id)
                                }
                                .contextMenu {
                                    Button {
                                        viewModel.toggleAutoStar(for: list.id)
                                    } label: {
                                        Label(
                                            list.isAutoStarActive ? "Disable Auto-Star" : "Enable Auto-Star",
                                            systemImage: list.isAutoStarActive ? "star.slash" : "star")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        viewModel.deleteList(list.id, deleteContainedClips: false)
                                    } label: {
                                        Label("Delete List", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    if let id = viewModel.selectedListId,
                        let list = viewModel.lists.first(where: { $0.id == id })
                    {
                        PanelIconButton(
                            title: list.isAutoStarActive ? "Disable Auto-Star" : "Enable Auto-Star",
                            systemImage: list.isAutoStarActive ? "star.circle.fill" : "star.circle"
                        ) {
                            viewModel.toggleAutoStar(for: id)
                        }
                    }
                }
            }
            if !viewModel.isSnippetsOnly {
                HStack(spacing: 5) {
                    ForEach(ClipTypeFilter.allCases) { filter in
                        TypeFilterPill(
                            filter: filter,
                            isSelected: viewModel.selectedTypeFilter == filter
                        ) {
                            viewModel.selectTypeFilter(filter)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var emptyClipsView: some View {
        if !viewModel.searchQuery.isEmpty {
            ClipboardEmptyState(
                title: "No matches",
                message: "Try another search in \(scopeName), or clear the search to see everything.",
                systemImage: "magnifyingglass", actionTitle: "Clear search"
            ) {
                viewModel.searchQuery = ""
                isFieldFocused = true
            }
        } else if viewModel.selectedTypeFilter != .all {
            ClipboardEmptyState(
                title: "No \(viewModel.selectedTypeFilter.displayName.lowercased()) items",
                message: "No clips matching '\(viewModel.selectedTypeFilter.displayName)' found in \(scopeName).",
                systemImage: viewModel.selectedTypeFilter.icon, actionTitle: "Show all types"
            ) {
                viewModel.selectTypeFilter(.all)
            }
        } else if viewModel.isFavoritesOnly {
            ClipboardEmptyState(
                title: "Keep the useful ones",
                message: "Star a clip in your history to find it here whenever you need it.", systemImage: "star")
        } else if viewModel.selectedListId != nil {
            ClipboardEmptyState(
                title: "This list is ready",
                message: "Move clips here from your history to keep related items together.", systemImage: "folder")
        } else {
            ClipboardEmptyState(
                title: "Your clipboard starts here",
                message: "Copy text, links or images. They’ll be ready here the next time you need them.",
                systemImage: "doc.on.clipboard")
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 10) {
            if let toast = viewModel.toastMessage {
                Label(toast, systemImage: "info.circle")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                viewModel.toggleQuickLook()
            } label: {
                Text("Preview")
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Preview selected clip (Space)")
            .disabled(viewModel.isSnippetsOnly || viewModel.clips.isEmpty)
            Button {
                viewModel.pasteSelected()
            } label: {
                HStack(spacing: 5) {
                    if let shortcut = shortcutsManager.shortcut(for: .pasteSelection) {
                        Text(shortcut.description).fontDesign(.monospaced)
                    }
                    Text(viewModel.isSnippetsOnly || settings.isDirectPasteEnabled ? "Paste" : "Copy")
                        .fontWeight(.semibold)
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(itemCount == 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private func promptCreateNewList() {
        let alert = NSAlert()
        alert.messageText = "New List"
        alert.informativeText = "Enter a name for the new list:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        textField.placeholderString = "List name..."
        alert.accessoryView = textField

        NSApp.activate()

        if let panel = NSApp.windows.first(where: { $0 is FloatingPanel }) {
            alert.window.initialFirstResponder = textField
            alert.beginSheetModal(for: panel) { response in
                if response == .alertFirstButtonReturn {
                    let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        viewModel.createNewList(name: name)
                    }
                }
            }
            textField.becomeFirstResponder()
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    viewModel.createNewList(name: name)
                }
            }
        }
    }
}

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
                SnippetsListView(viewModel: viewModel)
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
                                    rowContextMenu(for: clip)
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
                batchActions
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

    private var batchActions: some View {
        VStack(spacing: 10) {
            HStack {
                Label("\(viewModel.selectedClipIds.count) selected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Deselect", action: viewModel.clearSelection)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Deselect all (Esc)")
                if settings.isDirectPasteEnabled && viewModel.selectedClipIds.count > 1 {
                    Menu {
                        Button("Paste into form fields") {
                            viewModel.pasteSelectedBatch(mode: .sequentialFormFields(delayMs: 60))
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 28, height: 24)
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("More batch actions")
                }
            }
            HStack(spacing: 8) {
                if viewModel.selectedClipIds.count > 1 {
                    Picker("Join with", selection: $viewModel.batchSeparator) {
                        ForEach(BatchPasteSeparator.allCases, id: \.self) { separator in
                            Text(separator.displayName).tag(separator)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }
                Spacer(minLength: 4)
                Button(settings.isDirectPasteEnabled ? "Paste selected" : "Copy selected") {
                    viewModel.pasteSelected()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(ConCopyTheme.Surfaces.footerBackground)
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

    @ViewBuilder
    private func rowContextMenu(for clip: ClipRecord) -> some View {
        Button(action: {
            viewModel.copyClipToPasteboard(clip: clip)
        }) {
            Label("Copy to clipboard", systemImage: "doc.on.doc")
        }

        Button(action: {
            viewModel.paste(clip: clip)
        }) {
            Label("Paste", systemImage: "arrow.right.doc.on.clipboard")
        }

        Divider()

        Button(action: {
            if let index = viewModel.clips.firstIndex(where: { $0.id == clip.id }) {
                viewModel.selectedIndex = index
                viewModel.isQuickLookVisible = true
            }
        }) {
            Label("Quick Look", systemImage: "eye")
        }

        Button(action: {
            viewModel.editingClip = clip
        }) {
            Label("Edit Text...", systemImage: "pencil")
        }

        Divider()

        Button(clip.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            viewModel.toggleFavorite(clip: clip)
        }

        Menu("Move to List") {
            Button("No List (All)") {
                viewModel.assignClipToList(clip: clip, listId: nil)
            }
            ForEach(viewModel.lists) { list in
                Button(list.name) {
                    viewModel.assignClipToList(clip: clip, listId: list.id)
                }
            }
        }

        if clip.plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            Button {
                viewModel.createSnippetFromClip(clip)
            } label: {
                Label("Save as Snippet...", systemImage: "curlybraces")
            }
        }

        Menu("Paste as File") {
            Button("Text File (.txt)") {
                viewModel.pasteAsFile(clip: clip)
            }
            if clip.primaryType == .image {
                Button("PNG Image (.png)") {
                    viewModel.pasteAsFile(clip: clip, imageFormat: .png)
                }
                Button("JPEG Image (.jpg)") {
                    viewModel.pasteAsFile(clip: clip, imageFormat: .jpeg)
                }
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            viewModel.deleteClip(clip)
        }
    }
}

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

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material { nsView.material = material }
        if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
        if nsView.state != state { nsView.state = state }
    }
}

struct ListTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var shortcutHint: String? = nil
    let action: () -> Void

    var body: some View {
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

struct ClipRowView: View, Equatable {
    let clip: ClipRecord
    let index: Int
    let isSelected: Bool
    let isChecked: Bool
    let isPasting: Bool
    var isCopied: Bool = false
    var actionTitle: String = "Copy"
    let shortcutLabel: String?
    var quickPasteModifier: String = GlobalShortcutsManager.shared.quickPasteModifierSymbol
    var thumbnailImage: NSImage? = nil
    var fileIconImage: NSImage? = nil
    var appIconImage: NSImage? = nil
    var shouldMaskSensitive: Bool = false
    let onToggleCheck: () -> Void
    var onToggleFavorite: (() -> Void)? = nil
    var onRowClick: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isRevealedLocally: Bool = false
    @Environment(\.colorSchemeContrast) private var contrast

    static func == (lhs: ClipRowView, rhs: ClipRowView) -> Bool {
        lhs.clip == rhs.clip && lhs.index == rhs.index && lhs.isSelected == rhs.isSelected
            && lhs.isChecked == rhs.isChecked && lhs.isPasting == rhs.isPasting && lhs.isCopied == rhs.isCopied
            && lhs.actionTitle == rhs.actionTitle && lhs.shortcutLabel == rhs.shortcutLabel
            && lhs.quickPasteModifier == rhs.quickPasteModifier && lhs.thumbnailImage === rhs.thumbnailImage
            && lhs.fileIconImage === rhs.fileIconImage && lhs.shouldMaskSensitive == rhs.shouldMaskSensitive
    }

    private var accessibilityTitle: String {
        return String((clip.plainText ?? clip.primaryType.rawValue).prefix(160))
    }

    var body: some View {
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

                    let rawText = clip.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No preview available"
                    let displayText = (shouldMaskSensitive && !isRevealedLocally && !isHovered)
                        ? SensitiveDataDetector.maskSensitiveText(rawText)
                        : rawText

                    HStack(spacing: 6) {
                        Text(displayText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if shouldMaskSensitive {
                            Button {
                                if !isRevealedLocally {
                                    Task {
                                        let auth = await BiometricAuthenticator.authenticate(reason: "Authenticate with Touch ID to reveal sensitive clipboard content")
                                        if auth {
                                            isRevealedLocally = true
                                        }
                                    }
                                } else {
                                    isRevealedLocally = false
                                }
                            } label: {
                                Image(systemName: isRevealedLocally ? "lock.open.fill" : "lock.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isRevealedLocally ? ConCopyTheme.Accents.primary : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(isRevealedLocally ? "Sensitive data revealed (click to hide)" : "Protected sensitive data. Click or hover to reveal with Touch ID.")
                        }
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

struct MoveToListSheetView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @ObservedObject private var shortcutsManager = GlobalShortcutsManager.shared
    let clip: ClipRecord
    @State private var eventMonitor: Any? = nil

    var body: some View {
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
                        if clip.listId == nil {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(ConCopyTheme.Accents.primary)
                        }
                        Text("\(shortcutsManager.listModifierSymbol)A")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(ConCopyTheme.Surfaces.pillBackground)
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                clip.listId == nil
                                    ? ConCopyTheme.Rows.selectedBackground : ConCopyTheme.Surfaces.pillBackground)
                    )
                }
                .buttonStyle(.plain)

                // Fixed option "Favorites"
                Button(action: {
                    let wasFav = clip.isFavorite
                    viewModel.toggleFavorite(clip: clip)
                    viewModel.movingClip = nil
                    viewModel.showToast(wasFav ? "Removed from Favorites" : "Added to Favorites ★")
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .foregroundColor(ConCopyTheme.Accents.star)
                            .frame(width: 16)
                        Text(clip.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                            .font(.system(size: 13, weight: clip.isFavorite ? .semibold : .regular))
                        Spacer()
                        if clip.isFavorite {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(ConCopyTheme.Accents.primary)
                        }
                        Text("\(shortcutsManager.listModifierSymbol)1")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(ConCopyTheme.Surfaces.pillBackground)
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                clip.isFavorite
                                    ? ConCopyTheme.Rows.selectedBackground : ConCopyTheme.Surfaces.pillBackground)
                    )
                }
                .buttonStyle(.plain)

                // Opzione fissa "Snippet"
                Button(action: {
                    viewModel.convertMovingClipToSnippet()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ConCopyTheme.Accents.snippet)
                            .frame(width: 16)
                        Text("Snippet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(shortcutsManager.listModifierSymbol)2")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(ConCopyTheme.Surfaces.pillBackground)
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ConCopyTheme.Surfaces.pillBackground)
                    )
                }
                .buttonStyle(.plain)

                ForEach(Array(viewModel.lists.enumerated()), id: \.element.id) { index, list in
                    let digit = index + 3
                    Button(action: {
                        viewModel.assignClipToList(clip: clip, listId: list.id)
                        viewModel.movingClip = nil
                        viewModel.showToast("Moved to \"\(list.name)\"")
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .frame(width: 16)
                            Text(list.name)
                                .font(.system(size: 13, weight: clip.listId == list.id ? .semibold : .regular))
                            Spacer()
                            if clip.listId == list.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(ConCopyTheme.Accents.primary)
                            }
                            if digit <= 9 {
                                Text("\(shortcutsManager.listModifierSymbol)\(digit)")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                            .fill(ConCopyTheme.Surfaces.pillBackground)
                                    )
                            } else if digit == 10 {
                                Text("\(shortcutsManager.listModifierSymbol)0")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                            .fill(ConCopyTheme.Surfaces.pillBackground)
                                    )
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    clip.listId == list.id
                                        ? ConCopyTheme.Rows.selectedBackground : ConCopyTheme.Surfaces.pillBackground)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 260)

            HStack {
                Spacer()
                Button("Close") {
                    viewModel.movingClip = nil
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    viewModel.movingClip = nil
                    return nil
                }

                if shortcutsManager.matchesAllClips(event: event) {
                    viewModel.assignMovingClipToAll()
                    return nil
                }

                if let digit = shortcutsManager.matchedListDigit(for: event) {
                    viewModel.assignMovingClip(toOptionIndex: digit)
                    return nil
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

// MARK: - Snippets List View
struct SnippetsListView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @ObservedObject private var shortcutsManager = GlobalShortcutsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header bar with counter and "+ New Snippet" button
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ConCopyTheme.Accents.snippet)
                    Text("Snippets (\(viewModel.filteredSnippets.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    viewModel.editingSnippet = nil
                    viewModel.isSnippetEditorPresented = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("New Snippet")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(ConCopyTheme.Accents.snippet)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ConCopyTheme.Accents.snippetBackground)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.3)

            let displayedSnippets = viewModel.filteredSnippets

            if displayedSnippets.isEmpty {
                if !viewModel.searchQuery.isEmpty {
                    ClipboardEmptyState(
                        title: "No matching snippets",
                        message: "Try a different word or clear the search to see your saved snippets.",
                        systemImage: "magnifyingglass", actionTitle: "Clear search"
                    ) {
                        viewModel.searchQuery = ""
                    }
                } else {
                    ClipboardEmptyState(
                        title: "Less typing, more doing",
                        message: "Save the replies, signatures and text you use often.", systemImage: "curlybraces",
                        actionTitle: "Create a snippet"
                    ) {
                        viewModel.editingSnippet = nil
                        viewModel.isSnippetEditorPresented = true
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(displayedSnippets.enumerated()), id: \.element.id) { index, snippet in
                                let shortcut = shortcutsManager.quickPasteShortcut(for: index, searchFocused: viewModel.isSearchFocused)
                                SnippetRowView(
                                    snippet: snippet,
                                    index: index,
                                    isSelected: viewModel.selectedSnippetIndex == index,
                                    shortcutLabel: shortcut?.label,
                                    onSelect: { viewModel.selectedSnippetIndex = index },
                                    onPaste: {
                                        viewModel.selectedSnippetIndex = index
                                        viewModel.pasteSnippet(snippet)
                                    },
                                    onEdit: {
                                        viewModel.editingSnippet = snippet
                                        viewModel.isSnippetEditorPresented = true
                                    },
                                    onDelete: {
                                        viewModel.deleteSnippet(snippet)
                                    },
                                    quickPasteModifier: shortcut?.modifierSymbol ?? shortcutsManager.quickPasteModifierSymbol
                                )
                                .id(snippet.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: viewModel.selectedSnippetIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < displayedSnippets.count {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(displayedSnippets[newIndex].id, anchor: newIndex == 0 ? .top : .center)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Snippet Row View
struct SnippetRowView: View {
    let snippet: SnippetRecord
    let index: Int
    let isSelected: Bool
    let shortcutLabel: String?
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    var quickPasteModifier: String = GlobalShortcutsManager.shared.quickPasteModifierSymbol
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ConCopyTheme.Accents.snippet)
                        .frame(width: 30, height: 30)
                        .background(ConCopyTheme.Accents.snippetBackground, in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(
                                snippet.title?.isEmpty == false ? (snippet.title ?? snippet.shortcut) : snippet.shortcut
                            )
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            if snippet.title?.isEmpty == false {
                                Text(snippet.shortcut)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ConCopyTheme.Accents.snippet)
                                    .fixedSize()
                            }
                        }
                        Text(snippet.content.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let shortcutLabel {
                        PanelShortcutBadge(text: shortcutLabel, modifier: quickPasteModifier, isSelected: isSelected)
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select snippet \(snippet.title ?? snippet.shortcut)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help("Select this snippet, then press Return to paste")

            Menu {
                Button("Paste", action: onPaste)
                Button("Copy to clipboard", action: copySnippet)
                Button("Edit…", action: onEdit)
                Divider()
                Button("Delete snippet", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(snippet.title ?? snippet.shortcut)")
        }
        .padding(.horizontal, 10)
        .background(
            isSelected
                ? ConCopyTheme.Rows.selectedBackground : (isHovered ? ConCopyTheme.Rows.hoverBackground : Color.clear),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? ConCopyTheme.Rows.selectedBorder : Color.clear, lineWidth: 1)
        }
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy to clipboard", action: copySnippet)
            Button("Paste", action: onPaste)
            Button("Edit…", action: onEdit)
            Divider()
            Button("Delete snippet", role: .destructive, action: onDelete)
        }
    }

    private func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(Data(), forType: PasteInjector.internalPasteMarker)
        NSPasteboard.general.setString(snippet.content, forType: .string)
    }
}

// MARK: - Snippet Editor Sheet
struct SnippetEditorSheetView: View {
    let snippet: SnippetRecord?
    var errorMessage: String? = nil
    let onSave: (String, String, String?) -> Void
    let onCancel: () -> Void

    @State private var shortcut: String = ""
    @State private var content: String = ""
    @State private var title: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet == nil ? "New Snippet" : "Edit Snippet")
                .font(.headline)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }

            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcut (e.g. ;email or :sign)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(";shortcut", text: $shortcut)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label / Title (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. Personal Email", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Text Content")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $content)
                    .font(.system(size: 12))
                    .frame(height: 100)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(shortcut, content, title.isEmpty ? nil : title)
                }
                .disabled(shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 320)
        .onAppear {
            if let s = snippet {
                shortcut = s.shortcut
                content = s.content
                title = s.title ?? ""
            }
        }
    }
}

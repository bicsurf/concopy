import AppKit
import ConCopyCore
import SwiftUI

public struct ClipboardListView: View {
    @ObservedObject public var viewModel: ClipboardViewModel
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var shortcutsManager = GlobalShortcutsManager.shared
    @FocusState private var isFieldFocused: Bool
    @State private var editTextValue: String = ""
    @State private var editNameValue: String = ""
    @State private var isClearButtonHovered: Bool = false

    public init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Drag Handle Indicator
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ConCopyTheme.Surfaces.dragHandle)
                    .frame(width: 36, height: 4)
                Spacer()
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
            .background(WindowDragGestureArea())

            // Header: Search & Controls
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary)

                TextField("Cerca (Cmd+F)...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFieldFocused)
                    .onChange(of: isFieldFocused) { _, focused in
                        viewModel.isSearchFocused = focused
                    }
                    .onSubmit {
                        viewModel.pasteSelected()
                    }

                if !viewModel.searchQuery.isEmpty {
                    Button(action: { viewModel.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Sort Mode Menu
                Menu {
                    ForEach(ClipSortMode.allCases, id: \.self) { mode in
                        Button(action: {
                            viewModel.currentSortMode = mode
                            viewModel.loadClips()
                        }) {
                            HStack {
                                Text(mode.displayName)
                                if viewModel.currentSortMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help("Ordinamento")

                // Auto-Star toggle for selected list
                if let listId = viewModel.selectedListId,
                   let list = viewModel.lists.first(where: { $0.id == listId }) {
                    Button(action: {
                        viewModel.toggleAutoStar(for: listId)
                    }) {
                        Image(systemName: list.isAutoStarActive ? "star.circle.fill" : "star.circle")
                            .foregroundColor(list.isAutoStarActive ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Auto-Star su questa lista")
                }
                // Preferences button
                Button(action: {
                    if let onOpenSettings = viewModel.onOpenSettings {
                        onOpenSettings()
                    } else {
                        PreferencesWindowController.shared.showWindow()
                    }
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Impostazioni (⌘,)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Color.primary.opacity(0.02)
                    WindowDragGestureArea()
                }
            )

            // Update Available Banner
            if let update = updateChecker.availableUpdate {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(ConCopyTheme.Accents.primary)
                        .font(.system(size: 13))

                    Text("Nuova versione v\(update.version) disponibile")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)

                    Spacer()

                    Button("Scarica") {
                        if let url = update.dmgDownloadURL ?? URL(string: update.releasePageURL.absoluteString) {
                            NSWorkspace.shared.open(url)
                        }
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
                    .help("Nascondi per questa versione")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(ConCopyTheme.Badges.tabShortcutBackground(isSelected: true))
            }

            // Accessibility Permission Banner
            if !viewModel.isAccessibilityTrusted {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("Accessibilità mancante (incolla disabilitato)")
                        .font(.caption.bold())
                    Spacer()
                    Button("Impostazioni") {
                        viewModel.openAccessibilitySettings()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.yellow.opacity(0.12))
            }

            // Pause Warning Banner
            if AppSettingsManager.shared.isMonitoringPaused {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundColor(.orange)
                    Text("Registrazione in pausa")
                        .font(.caption.bold())
                    Spacer()
                    Button("Riprendi") {
                        AppSettingsManager.shared.isMonitoringPaused = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.12))
            }

            Divider().opacity(0.3)

            // Horizontal Lists Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ListTabButton(
                        title: "Tutte",
                        icon: "tray.full",
                        isSelected: viewModel.selectedListId == nil && !viewModel.isFavoritesOnly && !viewModel.isSnippetsOnly,
                        shortcutHint: "\(shortcutsManager.listModifierSymbol)1"
                    ) {
                        viewModel.selectAllClips()
                    }

                    ListTabButton(
                        title: "Preferiti",
                        icon: "star.fill",
                        isSelected: viewModel.selectedListId == nil && viewModel.isFavoritesOnly && !viewModel.isSnippetsOnly,
                        shortcutHint: "\(shortcutsManager.listModifierSymbol)2"
                    ) {
                        viewModel.selectFavorites()
                    }

                    ListTabButton(
                        title: "Snippet",
                        icon: "curlybraces",
                        isSelected: viewModel.isSnippetsOnly,
                        shortcutHint: "\(shortcutsManager.listModifierSymbol)3"
                    ) {
                        viewModel.selectSnippets()
                    }

                    ForEach(Array(viewModel.lists.enumerated()), id: \.element.id) { index, list in
                        ListTabButton(
                            title: list.name,
                            icon: list.isAutoStarActive ? "star.circle.fill" : "folder",
                            isSelected: !viewModel.isSnippetsOnly && viewModel.selectedListId == list.id,
                            shortcutHint: index + 4 <= 9 ? "\(shortcutsManager.listModifierSymbol)\(index + 4)" : nil
                        ) {
                            viewModel.selectList(list.id)
                        }
                        .contextMenu {
                            Button {
                                viewModel.toggleAutoStar(for: list.id)
                            } label: {
                                Label(
                                    list.isAutoStarActive ? "Disattiva Stella Automatica" : "Attiva Stella Automatica",
                                    systemImage: list.isAutoStarActive ? "star.slash" : "star"
                                )
                            }

                            Divider()

                            Button(role: .destructive) {
                                viewModel.deleteList(list.id, deleteContainedClips: false)
                            } label: {
                                Label("Elimina Lista", systemImage: "trash")
                            }
                        }
                    }

                    Button(action: promptCreateNewList) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(ConCopyTheme.Surfaces.pillBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(ConCopyTheme.Surfaces.pillBorder, lineWidth: 0.5)
                            )
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Crea nuova lista")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color.primary.opacity(0.015))

            Divider().opacity(0.3)

            // Main Content: Snippets or Clips
            if viewModel.isSnippetsOnly {
                SnippetsListView(viewModel: viewModel)
            } else if viewModel.clips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.bottom, 4)
                    Text("Nessun elemento negli appunti")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Copia del testo o immagini per salvarli automaticamente")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WindowDragGestureArea())
                .padding(.vertical, 40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(viewModel.clips.enumerated()), id: \.element.id) { index, clip in
                                ClipRowView(
                                    clip: clip,
                                    index: index,
                                    isSelected: viewModel.selectedIndex == index,
                                    isChecked: viewModel.selectedClipIds.contains(clip.id),
                                    isPasting: viewModel.pastingClipId == clip.id,
                                    shortcutLabel: QuickPasteShortcutMapper.label(forIndex: index),
                                    quickPasteModifier: shortcutsManager.quickPasteModifierSystemImage,
                                    thumbnailImage: clip.primaryType == .image ? viewModel.imageThumbnail(for: clip) : nil,
                                    fileIconImage: clip.primaryType == .file ? viewModel.fileIcon(for: clip) : nil,
                                    appIconImage: viewModel.appIcon(for: clip),
                                    onToggleCheck: {
                                        viewModel.toggleSelection(clipId: clip.id)
                                    },
                                    onToggleFavorite: {
                                        viewModel.toggleFavorite(clip: clip)
                                    }
                                )
                                .equatable()
                                .id("\(clip.id)-\(index)-\(clip.updatedAt.timeIntervalSince1970)-\(clip.customName ?? "")-\(clip.isFavorite)-\(shortcutsManager.swapNumericModifiers)")
                                .contentShape(Rectangle())
                                .contextMenu {
                                    rowContextMenu(for: clip)
                                }
                                .onTapGesture {
                                    let flags = NSEvent.modifierFlags
                                    if flags.contains(.shift) {
                                        viewModel.selectRange(to: clip)
                                    } else if flags.contains(.command) {
                                        viewModel.toggleSelection(for: clip)
                                    } else {
                                        if !viewModel.selectedClipIds.isEmpty {
                                            viewModel.toggleSelection(clipId: clip.id)
                                        } else {
                                            viewModel.selectSingle(clipId: clip.id)
                                        }
                                    }
                                }
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

            // Bottom Batch Actions Bar (when multi-selection is active)
            if !viewModel.selectedClipIds.isEmpty {
                Divider().opacity(0.3)
                HStack(spacing: 8) {
                    // Contatore selezionati
                    Text("\(viewModel.selectedClipIds.count) selezionati")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.leading, 2)

                    // Pulsante X minimale per deselezione
                    Button(action: {
                        viewModel.clearSelection()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isClearButtonHovered ? .primary : .secondary)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isClearButtonHovered ? ConCopyTheme.Rows.hoverBackground : ConCopyTheme.Surfaces.pillBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(ConCopyTheme.Surfaces.pillBorder, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Deseleziona tutto (Esc / ⌘D)")
                    .onHover { hovering in
                        isClearButtonHovered = hovering
                    }

                    Spacer()

                    if viewModel.selectedClipIds.count >= 2 {
                        Picker("", selection: $viewModel.batchSeparator) {
                            ForEach(BatchPasteSeparator.allCases, id: \.self) { sep in
                                Text(sep.displayName).tag(sep)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 120)

                        Button(viewModel.appSettings.isDirectPasteEnabled ? "Incolla Insieme" : "Copia Insieme") {
                            viewModel.pasteSelectedBatch(mode: .concatenated(separator: viewModel.batchSeparator))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Tab Modulo") {
                            viewModel.pasteSelectedBatch(mode: .sequentialFormFields(delayMs: 60))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button(viewModel.appSettings.isDirectPasteEnabled ? "Incolla" : "Copia") {
                            viewModel.pasteSelected()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
            }
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
        .overlay(alignment: .top) {
            if let toast = viewModel.toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .foregroundColor(.accentColor)
                    Text(toast)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .padding(.top, 40)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.2), value: viewModel.toastMessage)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isFieldFocused = true
                viewModel.isSearchFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            DispatchQueue.main.async {
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
            if viewModel.selectedIndex < viewModel.clips.count {
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
                Text("Modifica Testo")
                    .font(.headline)
                TextEditor(text: $editTextValue)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 380, minHeight: 200)
                    .padding(4)
                    .border(Color.secondary.opacity(0.2))

                HStack {
                    Spacer()
                    Button("Annulla") {
                        viewModel.editingClip = nil
                    }
                    Button("Salva") {
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
        // Rename / Custom Name sheet
        .sheet(item: $viewModel.renamingClip) { clip in
            VStack(alignment: .leading, spacing: 12) {
                Text("Aggiungi Nome Personalizzato")
                    .font(.headline)
                TextField("Nome / Etichetta...", text: $editNameValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 300)

                HStack {
                    if clip.customName != nil {
                        Button("Rimuovi Nome", role: .destructive) {
                            viewModel.saveCustomName(for: clip.id, newName: nil)
                        }
                    }
                    Spacer()
                    Button("Annulla") {
                        viewModel.renamingClip = nil
                    }
                    Button("Salva") {
                        viewModel.saveCustomName(for: clip.id, newName: editNameValue)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .onAppear {
                editNameValue = clip.customName ?? ""
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
                onSave: { shortcut, content, title in
                    viewModel.saveSnippet(
                        shortcut: shortcut,
                        content: content,
                        title: title,
                        existingId: viewModel.editingSnippet?.id
                    )
                    viewModel.isSnippetEditorPresented = false
                    viewModel.editingSnippet = nil
                },
                onCancel: {
                    viewModel.isSnippetEditorPresented = false
                    viewModel.editingSnippet = nil
                }
            )
        }
    }

    private func promptCreateNewList() {
        let alert = NSAlert()
        alert.messageText = "Nuova Lista"
        alert.informativeText = "Inserisci il nome per la nuova lista:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Crea")
        alert.addButton(withTitle: "Annulla")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        textField.placeholderString = "Nome lista..."
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
            Label("Copia negli appunti", systemImage: "doc.on.doc")
        }

        Button(action: {
            viewModel.paste(clip: clip)
        }) {
            Label("Incolla", systemImage: "arrow.right.doc.on.clipboard")
        }

        Divider()

        Button(action: {
            if let index = viewModel.clips.firstIndex(where: { $0.id == clip.id }) {
                viewModel.selectedIndex = index
                viewModel.isQuickLookVisible = true
            }
        }) {
            Label("Anteprima Rapida", systemImage: "eye")
        }

        Button(action: {
            viewModel.editingClip = clip
        }) {
            Label("Modifica Testo...", systemImage: "pencil")
        }

        Button(action: {
            viewModel.renamingClip = clip
        }) {
            Label(clip.customName == nil ? "Aggiungi Nome..." : "Rinomina...", systemImage: "tag")
        }

        Divider()

        Button(clip.isFavorite ? "Rimuovi dai Preferiti" : "Aggiungi ai Preferiti") {
            viewModel.toggleFavorite(clip: clip)
        }

        Menu("Sposta nella Lista") {
            Button("Nessuna Lista") {
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
                Label("Salva come Snippet...", systemImage: "curlybraces")
            }
        }

        Menu("Incolla come File") {
            Button("File di Testo (.txt)") {
                viewModel.pasteAsFile(clip: clip)
            }
            if clip.primaryType == .image {
                Button("Immagine PNG (.png)") {
                    viewModel.pasteAsFile(clip: clip, imageFormat: .png)
                }
                Button("Immagine JPEG (.jpg)") {
                    viewModel.pasteAsFile(clip: clip, imageFormat: .jpeg)
                }
            }
        }

        Divider()

        Button("Elimina", role: .destructive) {
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
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                if let hint = shortcutHint {
                    Text(hint)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(isSelected ? ConCopyTheme.Accents.primary : .secondary.opacity(0.7))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(ConCopyTheme.Badges.tabShortcutBackground(isSelected: isSelected))
                        )
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? ConCopyTheme.Rows.selectedBackground : ConCopyTheme.Surfaces.pillBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? ConCopyTheme.Rows.selectedBorder : ConCopyTheme.Surfaces.pillBorder, lineWidth: 1)
            )
            .foregroundColor(isSelected ? ConCopyTheme.Accents.primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct ClipRowView: View, Equatable {
    let clip: ClipRecord
    let index: Int
    let isSelected: Bool
    let isChecked: Bool
    let isPasting: Bool
    let shortcutLabel: String?
    var quickPasteModifier: String = GlobalShortcutsManager.shared.quickPasteModifierSystemImage
    var thumbnailImage: NSImage? = nil
    var fileIconImage: NSImage? = nil
    var appIconImage: NSImage? = nil
    let onToggleCheck: () -> Void
    var onToggleFavorite: (() -> Void)? = nil

    @State private var isHovered = false

    static func == (lhs: ClipRowView, rhs: ClipRowView) -> Bool {
        lhs.clip == rhs.clip &&
        lhs.index == rhs.index &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isChecked == rhs.isChecked &&
        lhs.isPasting == rhs.isPasting &&
        lhs.shortcutLabel == rhs.shortcutLabel &&
        lhs.quickPasteModifier == rhs.quickPasteModifier
    }

    var body: some View {
        HStack(spacing: 8) {
            // Checkbox for batch
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: isChecked ? .semibold : .regular))
                    .foregroundColor(isChecked ? .accentColor : .secondary.opacity(0.35))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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

            // Title and Preview
            VStack(alignment: .leading, spacing: 2) {
                if let custom = clip.customName, !custom.isEmpty {
                    Text(custom)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let text = clip.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    let text = clip.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "[Nessun contenuto]"
                    Text(text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            // Star Button (Favorite)
            Button(action: {
                onToggleFavorite?()
            }) {
                Image(systemName: clip.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10, weight: clip.isFavorite ? .bold : .regular))
                    .foregroundColor(
                        clip.isFavorite
                        ? ConCopyTheme.Accents.star
                        : (isHovered ? Color.secondary : Color.secondary.opacity(0.35))
                    )
                    .frame(width: 18, height: 18)
                    .background(
                        clip.isFavorite
                        ? ConCopyTheme.Accents.starBackground
                        : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    )
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(clip.isFavorite ? "Rimuovi dai Preferiti (Cmd+D)" : "Aggiungi ai Preferiti (Cmd+D)")

            // Shortcut Pill Badge
            if let label = shortcutLabel {
                HStack(spacing: 2) {
                    Image(systemName: quickPasteModifier)
                        .font(.system(size: 8.5, weight: .medium))
                    Text(label)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(ConCopyTheme.Badges.quickPasteForeground(isSelected: isSelected))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ConCopyTheme.Badges.quickPasteBackground(isSelected: isSelected))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(ConCopyTheme.Badges.quickPasteBorder(isSelected: isSelected), lineWidth: 0.5)
                )
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isPasting
                    ? ConCopyTheme.Rows.batchSelectedBackground
                    : (isSelected ? ConCopyTheme.Rows.selectedBackground : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? ConCopyTheme.Rows.selectedBorder : Color.clear, lineWidth: 1)
        )
        .scaleEffect(isPasting ? 0.98 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isPasting)
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
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
                    Text("Sposta nella Lista")
                        .font(.headline)
                    Text("Seleziona con click o \(shortcutsManager.listModifierSymbol)1..9")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider().opacity(0.3)

            VStack(spacing: 6) {
                Button(action: {
                    viewModel.assignClipToList(clip: clip, listId: nil)
                    viewModel.movingClip = nil
                    viewModel.showToast("Rimosso da tutte le liste")
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .frame(width: 16)
                        Text("Nessuna Lista (Tutte)")
                            .font(.system(size: 13, weight: clip.listId == nil ? .semibold : .regular))
                        Spacer()
                        if clip.listId == nil {
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
                            .fill(clip.listId == nil ? ConCopyTheme.Rows.selectedBackground : ConCopyTheme.Surfaces.pillBackground)
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
                        viewModel.showToast("Spostato in \"\(list.name)\"")
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
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(clip.listId == list.id ? ConCopyTheme.Rows.selectedBackground : ConCopyTheme.Surfaces.pillBackground)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 260)

            HStack {
                Spacer()
                Button("Chiudi") {
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
            // Header bar con contatore e pulsante "+ Nuovo Snippet"
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ConCopyTheme.Accents.snippet)
                    Text("Snippet (\(viewModel.filteredSnippets.count))")
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
                        Text("Nuovo Snippet")
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
                VStack(spacing: 8) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(ConCopyTheme.Accents.snippet.opacity(0.7))
                        .padding(.bottom, 4)

                    if !viewModel.searchQuery.isEmpty {
                        Text("Nessuno snippet corrisponde a \"\(viewModel.searchQuery)\"")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Premi Esc per svuotare la ricerca o crea un nuovo snippet.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.6))
                    } else {
                        Text("Nessuno snippet salvato")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Crea scorciatoie come ';email' o ';indirizzo' per espandere testi frequenti.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WindowDragGestureArea())
                .padding(.vertical, 40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(displayedSnippets.enumerated()), id: \.element.id) { index, snippet in
                                SnippetRowView(
                                    snippet: snippet,
                                    index: index,
                                    isSelected: viewModel.selectedSnippetIndex == index,
                                    shortcutLabel: QuickPasteShortcutMapper.label(forIndex: index),
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
                                    quickPasteModifier: shortcutsManager.quickPasteModifierSystemImage
                                )
                                .id("\(snippet.id)-\(index)-\(shortcutsManager.swapNumericModifiers)")
                                .onTapGesture {
                                    viewModel.selectedSnippetIndex = index
                                }
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
    let onPaste: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    var quickPasteModifier: String = GlobalShortcutsManager.shared.quickPasteModifierSystemImage

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Icona Snippet coerente (curlybraces in ambra)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ConCopyTheme.Accents.snippetBackground)
                    .frame(width: 24, height: 24)
                Image(systemName: "curlybraces")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(ConCopyTheme.Accents.snippet)
            }

            // Titolo, Keyword Badge e Anteprima del Contenuto
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let title = snippet.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    } else {
                        Text(snippet.shortcut)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }

                    // Keyword / Trigger badge
                    Text(snippet.shortcut)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(ConCopyTheme.Accents.snippet)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(ConCopyTheme.Accents.snippetBackground)
                        )
                }

                Text(snippet.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            // Azioni rapide visibili in hover
            if isHovered {
                HStack(spacing: 4) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(ConCopyTheme.Surfaces.pillBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Modifica Snippet...")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(ConCopyTheme.Surfaces.pillBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Elimina Snippet")
                }
            }

            // Shortcut Pill Badge (per incollaggio rapido)
            if let label = shortcutLabel {
                HStack(spacing: 2) {
                    Image(systemName: quickPasteModifier)
                        .font(.system(size: 8.5, weight: .medium))
                    Text(label)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(ConCopyTheme.Badges.quickPasteForeground(isSelected: isSelected))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ConCopyTheme.Badges.quickPasteBackground(isSelected: isSelected))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(ConCopyTheme.Badges.quickPasteBorder(isSelected: isSelected), lineWidth: 0.5)
                )
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? ConCopyTheme.Rows.selectedBackground : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? ConCopyTheme.Rows.selectedBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Copia negli appunti") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(Data(), forType: PasteInjector.internalPasteMarker)
                NSPasteboard.general.setString(snippet.content, forType: .string)
            }
            Button("Incolla") {
                onPaste()
            }
            Button("Modifica Snippet...") {
                onEdit()
            }
            Divider()
            Button("Elimina Snippet", role: .destructive) {
                onDelete()
            }
        }
    }
}

// MARK: - Snippet Editor Sheet
struct SnippetEditorSheetView: View {
    let snippet: SnippetRecord?
    let onSave: (String, String, String?) -> Void
    let onCancel: () -> Void

    @State private var shortcut: String = ""
    @State private var content: String = ""
    @State private var title: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet == nil ? "Nuovo Snippet" : "Modifica Snippet")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Scorciatoia (es. ;email o :firma)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(";shortcut", text: $shortcut)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Etichetta / Titolo (opzionale)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("es. Email Personale", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Contenuto di Testo")
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
                Button("Annulla", action: onCancel)
                Button("Salva") {
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

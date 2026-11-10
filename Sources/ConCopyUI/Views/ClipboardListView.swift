import ConCopyCore
import SwiftUI

public struct ClipboardListView: View {
    @ObservedObject public var viewModel: ClipboardViewModel
    @FocusState private var isFieldFocused: Bool
    @State private var isCreatingList: Bool = false
    @State private var newListName: String = ""
    @State private var editTextValue: String = ""
    @State private var editNameValue: String = ""

    public init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header: Search & Controls
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Cerca (Cmd+F)...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .onChange(of: isFieldFocused) { _, focused in
                        viewModel.isSearchFocused = focused
                    }

                if !viewModel.searchQuery.isEmpty {
                    Button(action: { viewModel.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Plain Text Mode Toggle ("T")
                Button(action: {
                    viewModel.isPlainTextModeEnabled.toggle()
                }) {
                    Text("T")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(viewModel.isPlainTextModeEnabled ? Color.accentColor : Color.secondary.opacity(0.15))
                        .foregroundColor(viewModel.isPlainTextModeEnabled ? .white : .primary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Modalità Solo Testo (Plain Text)")

                // Transformation Menu
                Menu {
                    ForEach(TextTransformation.allCases, id: \.self) { trans in
                        Button(action: {
                            viewModel.activeTransformation = trans
                        }) {
                            HStack {
                                Text(trans.displayName)
                                if viewModel.activeTransformation == trans {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: viewModel.activeTransformation == .none ? "textformat" : "textformat.size")
                        .foregroundColor(viewModel.activeTransformation == .none ? .secondary : .accentColor)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
                .help("Trasformazione Testo")

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
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
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
                    PreferencesWindowController.shared.showWindow()
                }) {
                    Image(systemName: "gearshape")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Preferenze (Cmd+,)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

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
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
            }

            Divider()

            // Horizontal Lists Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ListTabButton(
                        title: "Tutte",
                        icon: "tray.full",
                        isSelected: viewModel.selectedListId == nil && !viewModel.isFavoritesOnly
                    ) {
                        viewModel.selectAllClips()
                    }

                    ListTabButton(
                        title: "Preferiti",
                        icon: "star.fill",
                        isSelected: viewModel.isFavoritesOnly
                    ) {
                        viewModel.selectFavorites()
                    }

                    ForEach(viewModel.lists) { list in
                        ListTabButton(
                            title: list.name,
                            icon: list.isAutoStarActive ? "star.circle.fill" : "folder",
                            isSelected: viewModel.selectedListId == list.id
                        ) {
                            viewModel.selectList(list.id)
                        }
                    }

                    Button(action: {
                        isCreatingList.toggle()
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isCreatingList) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nuova Lista")
                                .font(.headline)
                            TextField("Nome lista...", text: $newListName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                            HStack {
                                Spacer()
                                Button("Annulla") {
                                    isCreatingList = false
                                    newListName = ""
                                }
                                Button("Crea") {
                                    viewModel.createNewList(name: newListName)
                                    newListName = ""
                                    isCreatingList = false
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(12)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))

            Divider()

            // Main List
            if viewModel.clips.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("Nessun elemento trovato")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(viewModel.clips.enumerated()), id: \.element.id) { index, clip in
                                ClipRowView(
                                    clip: clip,
                                    index: index,
                                    isSelected: viewModel.selectedIndex == index,
                                    isChecked: viewModel.selectedClipIds.contains(clip.id),
                                    shortcutLabel: QuickPasteShortcutMapper.label(forIndex: index),
                                    onToggleCheck: {
                                        viewModel.toggleSelection(clipId: clip.id)
                                    }
                                )
                                .id(index)
                                .contextMenu {
                                    rowContextMenu(for: clip)
                                }
                                .onTapGesture {
                                    viewModel.selectedIndex = index
                                }
                                .onTapGesture(count: 2) {
                                    viewModel.paste(at: index)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: viewModel.selectedIndex) { _, newIndex in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }

            // Bottom Batch Paste Bar (when >= 2 clips selected)
            if viewModel.selectedClipIds.count >= 2 {
                Divider()
                HStack(spacing: 8) {
                    Text("\(viewModel.selectedClipIds.count) selezionati")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Separatore", selection: $viewModel.batchSeparator) {
                        ForEach(BatchPasteSeparator.allCases, id: \.self) { sep in
                            Text(sep.displayName).tag(sep)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 130)

                    Button("Incolla Insieme") {
                        viewModel.pasteSelectedBatch(mode: .concatenated(separator: viewModel.batchSeparator))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Tab Modulo") {
                        viewModel.pasteSelectedBatch(mode: .sequentialFormFields(delayMs: 60))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        // QuickLook Popover
        .sheet(isPresented: $viewModel.isQuickLookVisible) {
            if viewModel.selectedIndex < viewModel.clips.count {
                QuickLookPopoverView(
                    clip: viewModel.clips[viewModel.selectedIndex],
                    databaseManager: viewModel.databaseManager,
                    onClose: {
                        viewModel.isQuickLookVisible = false
                    }
                )
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
    }

    @ViewBuilder
    private func rowContextMenu(for clip: ClipRecord) -> some View {
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

struct ListTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }
}

struct ClipRowView: View {
    let clip: ClipRecord
    let index: Int
    let isSelected: Bool
    let isChecked: Bool
    let shortcutLabel: String?
    let onToggleCheck: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isChecked ? .accentColor : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)

            if let label = shortcutLabel {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(width: 18, height: 18)
                    .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                    .foregroundColor(isSelected ? .white : .secondary)
            } else {
                Spacer().frame(width: 18)
            }

            typeIcon
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                if let custom = clip.customName, !custom.isEmpty {
                    Text(custom)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                }
                Text(clip.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "[Nessun testo]")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.9) : (clip.customName != nil ? .secondary : .primary))
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if clip.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 6)
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

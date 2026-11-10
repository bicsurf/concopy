import AppKit
import ConCopyCore
import SwiftUI

public struct ClipboardListView: View {
    @ObservedObject public var viewModel: ClipboardViewModel
    @FocusState private var isFieldFocused: Bool
    @State private var editTextValue: String = ""
    @State private var editNameValue: String = ""

    public init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Drag Handle Indicator
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.18))
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

                // Plain Text Mode Toggle ("T")
                Button(action: {
                    viewModel.isPlainTextModeEnabled.toggle()
                }) {
                    Text("T")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(viewModel.isPlainTextModeEnabled ? Color.accentColor : Color.primary.opacity(0.08))
                        )
                        .foregroundColor(viewModel.isPlainTextModeEnabled ? .white : .secondary)
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
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Preferenze (Cmd+,)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Color.primary.opacity(0.02)
                    WindowDragGestureArea()
                }
            )

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
                HStack(spacing: 5) {
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
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color.primary.opacity(0.015))

            Divider().opacity(0.3)

            // Main List
            if viewModel.clips.isEmpty {
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
                                    onToggleCheck: {
                                        viewModel.toggleSelection(clipId: clip.id)
                                    }
                                )
                                .id("\(clip.id)-\(clip.updatedAt.timeIntervalSince1970)-\(clip.customName ?? "")-\(clip.isFavorite)")
                                .contentShape(Rectangle())
                                .contextMenu {
                                    rowContextMenu(for: clip)
                                }
                                .onTapGesture(count: 2) {
                                    viewModel.paste(clip: clip)
                                }
                                .simultaneousGesture(
                                    TapGesture().onEnded {
                                        viewModel.selectedIndex = index
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        if isFieldFocused {
                            isFieldFocused = false
                            viewModel.isSearchFocused = false
                        }
                    })
                    .onChange(of: viewModel.selectedIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < viewModel.clips.count {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(viewModel.clips[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }

            // Bottom Batch Paste Bar (when >= 2 clips selected)
            if viewModel.selectedClipIds.count >= 2 {
                Divider().opacity(0.3)
                HStack(spacing: 8) {
                    Text("\(viewModel.selectedClipIds.count) selezionati")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Spacer()

                    Picker("", selection: $viewModel.batchSeparator) {
                        ForEach(BatchPasteSeparator.allCases, id: \.self) { sep in
                            Text(sep.displayName).tag(sep)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 120)

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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .background(
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
            isFieldFocused = false
            viewModel.isSearchFocused = false
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
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct ListTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .foregroundColor(isSelected ? .accentColor : .secondary)
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
    let onToggleCheck: () -> Void

    static func == (lhs: ClipRowView, rhs: ClipRowView) -> Bool {
        lhs.clip == rhs.clip &&
        lhs.index == rhs.index &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isChecked == rhs.isChecked &&
        lhs.isPasting == rhs.isPasting &&
        lhs.shortcutLabel == rhs.shortcutLabel
    }

    var body: some View {
        HStack(spacing: 9) {
            // Checkbox for batch
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isChecked ? .accentColor : .secondary.opacity(0.3))
            }
            .buttonStyle(.plain)

            // Type Icon Badge
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(typeBadgeBackground)
                    .frame(width: 24, height: 24)
                typeIcon
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(typeBadgeForeground)
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

            // Star Pill Badge
            if clip.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.yellow)
                    .padding(3)
                    .background(Color.yellow.opacity(0.15))
                    .clipShape(Circle())
            }

            // Shortcut Pill Badge
            if let label = shortcutLabel {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isPasting
                    ? Color.accentColor.opacity(0.4)
                    : (isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .scaleEffect(isPasting ? 0.98 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isPasting)
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
    }

    private var typeBadgeBackground: Color {
        switch clip.primaryType {
        case .text:
            return Color.blue.opacity(0.12)
        case .richText, .html:
            return Color.indigo.opacity(0.12)
        case .image:
            return Color.purple.opacity(0.12)
        case .url:
            return Color.teal.opacity(0.12)
        case .file:
            return Color.orange.opacity(0.12)
        case .color:
            return Color.pink.opacity(0.12)
        }
    }

    private var typeBadgeForeground: Color {
        switch clip.primaryType {
        case .text:
            return Color.blue
        case .richText, .html:
            return Color.indigo
        case .image:
            return Color.purple
        case .url:
            return Color.teal
        case .file:
            return Color.orange
        case .color:
            return Color.pink
        }
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

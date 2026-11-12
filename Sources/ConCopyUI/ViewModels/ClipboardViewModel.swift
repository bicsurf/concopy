import AppKit
import ApplicationServices
import Combine
import ConCopyCore
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class ClipboardViewModel: ObservableObject {
    @Published public var clips: [ClipRecord] = []
    @Published public var lists: [ClipListRecord] = []
    @Published public var selectedListId: UUID? = nil
    @Published public var isFavoritesOnly: Bool = false
    @Published public var searchQuery: String = "" {
        didSet {
            if isSnippetsOnly {
                if selectedSnippetIndex >= filteredSnippets.count {
                    selectedSnippetIndex = max(0, filteredSnippets.count - 1)
                }
            } else {
                loadClips()
            }
        }
    }
    @Published public var isPlainTextModeEnabled: Bool = false
    @Published public var activeTransformation: TextTransformation = .none
    @Published public var currentSortMode: ClipSortMode = .updatedAtDesc
    @Published public var selectedIndex: Int = 0
    @Published public var selectedClipIds: Set<UUID> = []
    public private(set) var selectionAnchorId: UUID? = nil

    public var selectedClipId: UUID? {
        get {
            guard selectedIndex >= 0 && selectedIndex < clips.count else { return nil }
            return clips[selectedIndex].id
        }
        set {
            if let newId = newValue, let idx = clips.firstIndex(where: { $0.id == newId }) {
                selectedIndex = idx
            }
        }
    }
    public var isSelectionMode: Bool {
        !selectedClipIds.isEmpty
    }
    public var filteredClips: [ClipRecord] {
        clips
    }
    public var filteredSnippets: [SnippetRecord] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return snippets }
        return snippets.filter { snippet in
            snippet.shortcut.lowercased().contains(q) ||
            snippet.content.lowercased().contains(q) ||
            (snippet.title?.lowercased().contains(q) == true)
        }
    }
    @Published public var scrollTargetTopTrigger: UUID? = nil
    private var lastTopClipId: UUID? = nil
    private var lastTopClipUpdatedAt: Date? = nil
    @Published public var batchSeparator: BatchPasteSeparator = .newline
    @Published public var isSearchFocused: Bool = false
    @Published public var isQuickLookVisible: Bool = false
    @Published public var editingClip: ClipRecord? = nil
    @Published public var renamingClip: ClipRecord? = nil
    @Published public var movingClip: ClipRecord? = nil
    @Published public var pastingClipId: UUID? = nil
    @Published public var isAccessibilityTrusted: Bool = true
    @Published public var toastMessage: String? = nil
    @Published public var snippets: [SnippetRecord] = []
    @Published public var selectedSnippetIndex: Int = 0
    @Published public var isSnippetsOnly: Bool = false
    @Published public var isSnippetEditorPresented: Bool = false
    @Published public var editingSnippet: SnippetRecord? = nil

    private var thumbnailCache = NSCache<NSUUID, NSImage>()

    public let databaseManager: DatabaseManager
    public let pasteInjector: PasteInjector
    public let appSettings: AppSettingsManager
    public var onClosePanel: (() -> Void)?
    public var onOpenSettings: (() -> Void)?

    public init(
        databaseManager: DatabaseManager,
        pasteInjector: PasteInjector = PasteInjector(),
        appSettings: AppSettingsManager
    ) {
        self.databaseManager = databaseManager
        self.pasteInjector = pasteInjector
        self.appSettings = appSettings
        checkAccessibilityPermissions()
        loadLists()
        loadClips()
        loadSnippets()
    }

    public convenience init(
        databaseManager: DatabaseManager,
        pasteInjector: PasteInjector = PasteInjector()
    ) {
        self.init(
            databaseManager: databaseManager,
            pasteInjector: pasteInjector,
            appSettings: .shared
        )
    }

    public func checkAccessibilityPermissions() {
        self.isAccessibilityTrusted = pasteInjector.eventPoster.isProcessTrusted()
    }

    public func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func clearHistory(preserveFavorites: Bool = true) {
        do {
            _ = try databaseManager.clearAllHistory(preserveFavorites: preserveFavorites)
            loadClips()
        } catch {
            print("[ConCopy] Failed to clear history: \(error)")
        }
    }

    public func toggleQuickLook() {
        isQuickLookVisible.toggle()
    }

    public func saveEditedText(for clipId: UUID, newText: String) {
        do {
            try databaseManager.updateTextContent(clipId: clipId, newPlainText: newText)
            editingClip = nil
            loadClips()
        } catch {
            print("[ConCopy] Failed to update text content: \(error)")
        }
    }

    public func saveCustomName(for clipId: UUID, newName: String?) {
        do {
            try databaseManager.updateCustomName(clipId: clipId, name: newName)
            renamingClip = nil
            loadClips()
        } catch {
            print("[ConCopy] Failed to update custom name: \(error)")
        }
    }

    public func loadLists() {
        do {
            self.lists = try databaseManager.fetchLists()
        } catch {
            print("[ConCopy] Error loading lists: \(error)")
        }
    }

    public func loadClips() {
        do {
            let fetched = try databaseManager.searchClips(
                query: searchQuery,
                listId: selectedListId,
                favoritesOnly: isFavoritesOnly,
                sortMode: currentSortMode
            )

            let isNewTopClip: Bool
            if let first = fetched.first {
                if let lastId = lastTopClipId {
                    isNewTopClip = (first.id != lastId) || (lastTopClipUpdatedAt != nil && first.updatedAt > lastTopClipUpdatedAt!)
                } else {
                    isNewTopClip = true
                }
            } else {
                isNewTopClip = false
            }

            self.clips = fetched
            self.lastTopClipId = fetched.first?.id
            self.lastTopClipUpdatedAt = fetched.first?.updatedAt

            if isNewTopClip && !isSelectionMode {
                selectedClipId = fetched.first?.id
                selectedClipIds.removeAll()
                selectionAnchorId = nil
                scrollTargetTopTrigger = UUID()
            } else if selectedIndex >= clips.count {
                selectedIndex = max(0, clips.count - 1)
            }
        } catch {
            print("[ConCopy] Error loading clips: \(error)")
        }
    }

    public func selectMostRecentClip() {
        guard !clips.isEmpty else { return }
        selectedClipId = filteredClips.first?.id
        if !isSelectionMode {
            selectedClipIds.removeAll()
            selectionAnchorId = nil
        }
        scrollTargetTopTrigger = UUID()
    }

    public func prepareForPanelOpen() {
        if !searchQuery.isEmpty {
            searchQuery = ""
        }
        checkAccessibilityPermissions()
        loadClips()
        selectMostRecentClip()
    }

    public func selectAllClips() {
        selectedListId = nil
        isFavoritesOnly = false
        isSnippetsOnly = false
        loadClips()
    }

    public func selectFavorites() {
        selectedListId = nil
        isFavoritesOnly = true
        isSnippetsOnly = false
        loadClips()
    }

    public func selectSnippets() {
        selectedListId = nil
        isFavoritesOnly = false
        isSnippetsOnly = true
        loadSnippets()
    }

    public func selectList(_ listId: UUID) {
        selectedListId = listId
        isFavoritesOnly = false
        isSnippetsOnly = false
        if let list = lists.first(where: { $0.id == listId }) {
            currentSortMode = list.sortMode
        }
        loadClips()
    }

    public func createNewList(name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let list = try databaseManager.createList(name: name)
            loadLists()
            selectList(list.id)
        } catch {
            print("[ConCopy] Failed to create list: \(error)")
        }
    }

    public func deleteList(_ listId: UUID, deleteContainedClips: Bool = false) {
        do {
            try databaseManager.deleteList(listId: listId, deleteContainedClips: deleteContainedClips)
            loadLists()
            if selectedListId == listId {
                selectAllClips()
            }
        } catch {
            print("[ConCopy] Failed to delete list: \(error)")
        }
    }

    public func toggleAutoStar(for listId: UUID) {
        do {
            if let list = lists.first(where: { $0.id == listId }) {
                let willActivate = !list.isAutoStarActive
                try databaseManager.setAutoStarList(listId: willActivate ? listId : nil)
            } else {
                try databaseManager.setAutoStarList(listId: listId)
            }
            loadLists()
        } catch {
            print("[ConCopy] Failed to set auto star list: \(error)")
        }
    }

    public func selectSingle(clipId: UUID) {
        selectedClipIds.removeAll()
        selectedClipId = clipId
        selectionAnchorId = clipId
    }

    public func toggleSelection(for clip: ClipRecord) {
        toggleSelection(clipId: clip.id)
    }

    public func toggleSelection(clipId: UUID) {
        if selectedClipIds.contains(clipId) {
            selectedClipIds.remove(clipId)
        } else {
            selectedClipIds.insert(clipId)
        }
        selectedClipId = clipId
        selectionAnchorId = clipId
    }

    public func selectRange(to clip: ClipRecord) {
        selectRange(toClipId: clip.id)
    }

    public func selectRange(toClipId clipId: UUID) {
        guard !clips.isEmpty else { return }

        let anchorId = selectionAnchorId ?? selectedClipId
        let startIndex: Int
        if let anchorId = anchorId, let found = clips.firstIndex(where: { $0.id == anchorId }) {
            startIndex = found
        } else {
            startIndex = 0
        }

        let endIndex = clips.firstIndex(where: { $0.id == clipId }) ?? 0
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)

        var newSelection: Set<UUID> = []
        for idx in range {
            newSelection.insert(clips[idx].id)
        }
        selectedClipIds = newSelection
        selectedClipId = clipId
        // Keep selectionAnchorId intact for subsequent extensions/contractions
        if selectionAnchorId == nil {
            selectionAnchorId = clips[startIndex].id
        }
    }

    public func moveSelection(by offset: Int, extendSelection: Bool) {
        if isSnippetsOnly {
            let count = filteredSnippets.count
            guard count > 0 else { return }
            let newIndex = max(0, min(count - 1, selectedSnippetIndex + offset))
            selectedSnippetIndex = newIndex
            return
        }

        guard !clips.isEmpty else { return }

        if !extendSelection {
            selectedClipIds.removeAll()
            let newIndex = max(0, min(clips.count - 1, selectedIndex + offset))
            selectedIndex = newIndex
            selectionAnchorId = selectedClipId
            return
        }

        // Shift is held: extend or contract range with respect to selectionAnchorId
        if selectionAnchorId == nil {
            selectionAnchorId = selectedClipId
        }

        let anchorIndex: Int
        if let anchorId = selectionAnchorId, let idx = clips.firstIndex(where: { $0.id == anchorId }) {
            anchorIndex = idx
        } else {
            anchorIndex = selectedIndex
            selectionAnchorId = selectedClipId
        }

        let targetIndex = max(0, min(clips.count - 1, selectedIndex + offset))
        selectedIndex = targetIndex

        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        var newSelection: Set<UUID> = []
        for idx in range {
            newSelection.insert(clips[idx].id)
        }
        selectedClipIds = newSelection
    }

    public func moveSelectionUp(expandSelection: Bool = false) {
        moveSelection(by: -1, extendSelection: expandSelection)
    }

    public func moveSelectionDown(expandSelection: Bool = false) {
        moveSelection(by: 1, extendSelection: expandSelection)
    }

    public func clearSelection() {
        selectedClipIds.removeAll()
        selectionAnchorId = selectedClipId
    }

    public func showToast(_ message: String, duration: TimeInterval = 2.5) {
        self.toastMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if self?.toastMessage == message {
                self?.toastMessage = nil
            }
        }
    }

    public func pasteSelected(optionHeld: Bool = false) {
        if isSnippetsOnly {
            if selectedSnippetIndex >= 0 && selectedSnippetIndex < filteredSnippets.count {
                pasteSnippet(filteredSnippets[selectedSnippetIndex])
            }
            return
        }
        if selectedClipIds.count >= 2 {
            pasteSelectedBatch(mode: .concatenated(separator: batchSeparator))
        } else if let singleId = selectedClipIds.first, let clip = clips.first(where: { $0.id == singleId }) {
            paste(clip: clip, optionHeld: optionHeld)
        } else if selectedIndex >= 0 && selectedIndex < clips.count {
            paste(clip: clips[selectedIndex], optionHeld: optionHeld)
        }
    }

    public func paste(at index: Int, optionHeld: Bool = false) {
        guard index >= 0 && index < clips.count else { return }
        selectedIndex = index
        paste(clip: clips[index], optionHeld: optionHeld)
    }

    public func paste(clip: ClipRecord, optionHeld: Bool = false) {
        guard pastingClipId == nil else { return }
        if let index = clips.firstIndex(where: { $0.id == clip.id }) {
            selectedIndex = index
        }
        self.pastingClipId = clip.id
        let forcePlainText = optionHeld || isPlainTextModeEnabled
        let transformation = activeTransformation
        let isTrusted = pasteInjector.eventPoster.isProcessTrusted()

        if !appSettings.isDirectPasteEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try self.pasteInjector.copyToPasteboard(
                        clip: clip,
                        databaseManager: self.databaseManager,
                        forcePlainText: forcePlainText,
                        transformation: transformation
                    )
                    self.onClosePanel?()
                    self.pastingClipId = nil
                    self.loadClips()
                } catch {
                    self.pastingClipId = nil
                    print("[ConCopy] Failed to copy clip: \(error)")
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if !isTrusted {
                    self.showToast("Copiato negli appunti! Premi ⌘V per incollare.")
                }
                try await self.pasteInjector.paste(
                    clip: clip,
                    databaseManager: self.databaseManager,
                    forcePlainText: forcePlainText,
                    transformation: transformation,
                    beforeEventHook: { [weak self] in
                        if isTrusted {
                            self?.onClosePanel?()
                        } else {
                            Task { @MainActor [weak self] in
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                self?.onClosePanel?()
                                self?.loadClips()
                            }
                        }
                    }
                )
                self.pastingClipId = nil
                if isTrusted {
                    self.loadClips()
                }
            } catch {
                self.pastingClipId = nil
                print("[ConCopy] Failed to paste clip: \(error)")
            }
        }
    }

    public func pasteSelectedBatch(mode: BatchPasteMode) {
        let orderedClips: [ClipRecord]
        if !selectedClipIds.isEmpty {
            orderedClips = clips.filter { selectedClipIds.contains($0.id) }
        } else if selectedIndex < clips.count {
            orderedClips = [clips[selectedIndex]]
        } else {
            return
        }

        let transformation = activeTransformation
        let isTrusted = pasteInjector.eventPoster.isProcessTrusted()

        if !appSettings.isDirectPasteEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try self.pasteInjector.copyBatchToPasteboard(
                        clips: orderedClips,
                        mode: mode,
                        transformation: transformation,
                        databaseManager: self.databaseManager
                    )
                    self.onClosePanel?()
                    self.selectedClipIds.removeAll()
                    self.loadClips()
                } catch {
                    print("[ConCopy] Failed to batch copy clips: \(error)")
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if !isTrusted {
                    self.showToast("Testo copiato negli appunti! Premi ⌘V per incollare.")
                }
                try await self.pasteInjector.pasteBatch(
                    clips: orderedClips,
                    mode: mode,
                    transformation: transformation,
                    databaseManager: self.databaseManager,
                    beforeEventHook: { [weak self] in
                        if isTrusted {
                            self?.onClosePanel?()
                        } else {
                            Task { @MainActor [weak self] in
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                self?.onClosePanel?()
                                self?.loadClips()
                            }
                        }
                    }
                )
                if isTrusted {
                    self.loadClips()
                }
            } catch {
                print("[ConCopy] Failed to batch paste clips: \(error)")
            }
        }
    }

    public func copySelectedToPasteboard() {
        if isSnippetsOnly {
            if selectedSnippetIndex >= 0 && selectedSnippetIndex < filteredSnippets.count {
                let snippet = filteredSnippets[selectedSnippetIndex]
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(Data(), forType: PasteInjector.internalPasteMarker)
                NSPasteboard.general.setString(snippet.content, forType: .string)
                showToast("Snippet copiato negli appunti!")
                onClosePanel?()
            }
            return
        }

        if !selectedClipIds.isEmpty {
            let ordered = clips.filter { selectedClipIds.contains($0.id) }
            if !ordered.isEmpty {
                do {
                    try pasteInjector.copyBatchToPasteboard(
                        clips: ordered,
                        mode: .concatenated(separator: batchSeparator),
                        transformation: activeTransformation,
                        databaseManager: databaseManager
                    )
                    showToast("Copiati \(ordered.count) elementi negli appunti!")
                    onClosePanel?()
                    loadClips()
                } catch {
                    print("[ConCopy] Failed to copy batch to pasteboard: \(error)")
                }
                return
            }
        }

        if selectedIndex >= 0 && selectedIndex < clips.count {
            let clip = clips[selectedIndex]
            copyClipToPasteboard(clip: clip)
        }
    }

    public func copyClipToPasteboard(clip: ClipRecord) {
        do {
            try pasteInjector.copyToPasteboard(
                clip: clip,
                databaseManager: databaseManager,
                forcePlainText: isPlainTextModeEnabled,
                transformation: activeTransformation
            )
            showToast("Copiato negli appunti!")
            onClosePanel?()
            loadClips()
        } catch {
            print("[ConCopy] Failed to copy clip to pasteboard: \(error)")
        }
    }

    public func pasteAsFile(clip: ClipRecord, imageFormat: ImageExportFormat = .png) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.pasteInjector.pasteAsFile(
                    clip: clip,
                    imageFormat: imageFormat,
                    databaseManager: self.databaseManager,
                    beforeEventHook: { [weak self] in
                        self?.onClosePanel?()
                    }
                )
                self.loadClips()
            } catch {
                print("[ConCopy] Failed to paste as file: \(error)")
            }
        }
    }

    public func toggleFavorite(clip: ClipRecord) {
        do {
            _ = try databaseManager.toggleFavorite(clipId: clip.id)
            loadClips()
        } catch {
            print("[ConCopy] Failed to toggle favorite: \(error)")
        }
    }

    public func toggleFavoriteSelected() {
        if !selectedClipIds.isEmpty {
            for clipId in selectedClipIds {
                _ = try? databaseManager.toggleFavorite(clipId: clipId)
            }
            loadClips()
            showToast("Preferiti aggiornati ★")
        } else if selectedIndex >= 0 && selectedIndex < clips.count {
            let clip = clips[selectedIndex]
            toggleFavorite(clip: clip)
            showToast(clip.isFavorite ? "Rimosso dai Preferiti" : "Aggiunto ai Preferiti ★")
        }
    }

    public func promptMoveSelectedClipToList() {
        guard selectedIndex >= 0 && selectedIndex < clips.count else { return }
        let clip = clips[selectedIndex]
        self.movingClip = clip
    }

    public func assignClipToList(clip: ClipRecord, listId: UUID?) {
        do {
            _ = try databaseManager.assignClip(clipId: clip.id, toListId: listId)
            loadClips()
        } catch {
            print("[ConCopy] Failed to assign clip to list: \(error)")
        }
    }

    public func assignSelectedClipsToList(listId: UUID?) {
        for clipId in selectedClipIds {
            do {
                _ = try databaseManager.assignClip(clipId: clipId, toListId: listId)
            } catch {
                print("[ConCopy] Failed to assign clip \(clipId) to list: \(error)")
            }
        }
        loadClips()
    }

    public func convertMovingClipToSnippet() {
        guard let clip = movingClip else { return }
        movingClip = nil
        createSnippetFromClip(clip)
    }

    public func assignMovingClipToAll() {
        guard let clip = movingClip else { return }
        assignClipToList(clip: clip, listId: nil)
        movingClip = nil
        showToast("Rimosso da tutte le liste")
    }

    public func assignMovingClip(toOptionIndex digit: Int) {
        guard let clip = movingClip else { return }
        if digit == 1 {
            let wasFav = clip.isFavorite
            toggleFavorite(clip: clip)
            movingClip = nil
            showToast(wasFav ? "Rimosso dai Preferiti" : "Aggiunto ai Preferiti ★")
        } else if digit == 2 {
            convertMovingClipToSnippet()
        } else {
            let listIndex = digit == 0 ? 7 : (digit - 3)
            if listIndex >= 0 && listIndex < lists.count {
                let list = lists[listIndex]
                assignClipToList(clip: clip, listId: list.id)
                movingClip = nil
                showToast("Spostato in \"\(list.name)\"")
            }
        }
    }

    public func deleteClip(_ clip: ClipRecord) {
        do {
            try databaseManager.deleteClip(clipId: clip.id)
            selectedClipIds.remove(clip.id)
            loadClips()
        } catch {
            print("[ConCopy] Failed to delete clip: \(error)")
        }
    }

    // MARK: - Snippets Management
    public func loadSnippets() {
        do {
            snippets = try databaseManager.fetchSnippets()
            if selectedSnippetIndex >= filteredSnippets.count {
                selectedSnippetIndex = max(0, filteredSnippets.count - 1)
            }
        } catch {
            print("[ConCopy] Failed to load snippets: \(error)")
        }
    }

    public func createSnippetFromClip(_ clip: ClipRecord) {
        let text = clip.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        let autoTitle = clip.customName ?? (text.count > 30 ? String(text.prefix(30)) + "..." : text)
        let placeholder = SnippetRecord(
            shortcut: ";",
            content: text,
            title: autoTitle
        )
        editingSnippet = placeholder
        isSnippetEditorPresented = true
    }

    public func saveSnippet(shortcut: String, content: String, title: String? = nil, existingId: UUID? = nil) {
        let trimmedShortcut = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShortcut.isEmpty, !content.isEmpty else { return }
        let snippet = SnippetRecord(
            id: existingId ?? UUID(),
            shortcut: trimmedShortcut,
            content: content,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title : nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        do {
            try databaseManager.saveSnippet(snippet)
            loadSnippets()
            showToast("Snippet salvato: \(snippet.shortcut)")
        } catch {
            print("[ConCopy] Failed to save snippet: \(error)")
            showToast("Errore nel salvataggio dello snippet")
        }
    }

    public func deleteSnippet(_ snippet: SnippetRecord) {
        do {
            try databaseManager.deleteSnippet(id: snippet.id)
            loadSnippets()
            showToast("Snippet eliminato")
        } catch {
            print("[ConCopy] Failed to delete snippet: \(error)")
        }
    }

    public func pasteSnippet(_ snippet: SnippetRecord) {
        let isTrusted = pasteInjector.eventPoster.isProcessTrusted()
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet.content, forType: .string)
                NSPasteboard.general.setString("1", forType: PasteInjector.internalPasteMarker)
                self.onClosePanel?()
                try await Task.sleep(nanoseconds: 80_000_000)
                if isTrusted {
                    _ = self.pasteInjector.eventPoster.postCommandV()
                }
            } catch {
                print("[ConCopy] Failed to paste snippet: \(error)")
            }
        }
    }

    // MARK: - Image / File Thumbnail Helper
    public func imageThumbnail(for clip: ClipRecord) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: clip.id as NSUUID) {
            return cached
        }
        guard clip.primaryType == .image else { return nil }
        guard let payloads = try? databaseManager.fetchPayloads(forClipId: clip.id),
              let imgPayload = payloads.first(where: { $0.utiType == "public.png" || $0.utiType == "public.tiff" }),
              let data = try? databaseManager.loadPayloadData(for: imgPayload),
              let image = NSImage(data: data) else {
            return nil
        }
        thumbnailCache.setObject(image, forKey: clip.id as NSUUID)
        return image
    }

    public func fileIcon(for clip: ClipRecord) -> NSImage? {
        guard clip.primaryType == .file else { return nil }
        guard let payloads = try? databaseManager.fetchPayloads(forClipId: clip.id),
              let filePayload = payloads.first(where: { $0.utiType == "public.file-url" }),
              let data = try? databaseManager.loadPayloadData(for: filePayload),
              let urlString = String(data: data, encoding: .utf8),
              let fileURL = URL(string: urlString) else {
            if let text = clip.plainText, text.hasPrefix("/") {
                return NSWorkspace.shared.icon(forFile: text)
            }
            if #available(macOS 12.0, *), let utType = UTType(filenameExtension: "txt") {
                return NSWorkspace.shared.icon(for: utType)
            } else {
                return NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            }
        }
        return NSWorkspace.shared.icon(forFile: fileURL.path)
    }

    public func appIcon(for clip: ClipRecord) -> NSImage? {
        AppIconProvider.shared.icon(for: clip.sourceAppBundleId)
    }
}

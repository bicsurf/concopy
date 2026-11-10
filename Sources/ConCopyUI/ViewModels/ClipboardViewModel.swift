import AppKit
import ApplicationServices
import Combine
import ConCopyCore
import Foundation

@MainActor
public final class ClipboardViewModel: ObservableObject {
    @Published public var clips: [ClipRecord] = []
    @Published public var lists: [ClipListRecord] = []
    @Published public var selectedListId: UUID? = nil
    @Published public var isFavoritesOnly: Bool = false
    @Published public var searchQuery: String = "" {
        didSet {
            loadClips()
        }
    }
    @Published public var isPlainTextModeEnabled: Bool = false
    @Published public var activeTransformation: TextTransformation = .none
    @Published public var currentSortMode: ClipSortMode = .updatedAtDesc
    @Published public var selectedIndex: Int = 0
    @Published public var selectedClipIds: Set<UUID> = []
    @Published public var batchSeparator: BatchPasteSeparator = .newline
    @Published public var isSearchFocused: Bool = false
    @Published public var isQuickLookVisible: Bool = false
    @Published public var editingClip: ClipRecord? = nil
    @Published public var renamingClip: ClipRecord? = nil
    @Published public var pastingClipId: UUID? = nil
    @Published public var isAccessibilityTrusted: Bool = true
    @Published public var toastMessage: String? = nil

    public let databaseManager: DatabaseManager
    public let pasteInjector: PasteInjector
    public var onClosePanel: (() -> Void)?

    public init(
        databaseManager: DatabaseManager,
        pasteInjector: PasteInjector = PasteInjector()
    ) {
        self.databaseManager = databaseManager
        self.pasteInjector = pasteInjector
        checkAccessibilityPermissions()
        loadLists()
        loadClips()
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
            self.clips = try databaseManager.searchClips(
                query: searchQuery,
                listId: selectedListId,
                favoritesOnly: isFavoritesOnly,
                sortMode: currentSortMode
            )
            if selectedIndex >= clips.count {
                selectedIndex = max(0, clips.count - 1)
            }
        } catch {
            print("[ConCopy] Error loading clips: \(error)")
        }
    }

    public func selectAllClips() {
        selectedListId = nil
        isFavoritesOnly = false
        loadClips()
    }

    public func selectFavorites() {
        selectedListId = nil
        isFavoritesOnly = true
        loadClips()
    }

    public func selectList(_ listId: UUID) {
        selectedListId = listId
        isFavoritesOnly = false
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

    public func moveSelectionUp(expandSelection: Bool = false) {
        if selectedIndex > 0 {
            selectedIndex -= 1
            if expandSelection, selectedIndex < clips.count {
                selectedClipIds.insert(clips[selectedIndex].id)
            } else if !expandSelection {
                selectedClipIds.removeAll()
            }
        }
    }

    public func moveSelectionDown(expandSelection: Bool = false) {
        if selectedIndex < clips.count - 1 {
            selectedIndex += 1
            if expandSelection, selectedIndex < clips.count {
                selectedClipIds.insert(clips[selectedIndex].id)
            } else if !expandSelection {
                selectedClipIds.removeAll()
            }
        }
    }

    public func toggleSelection(clipId: UUID) {
        if selectedClipIds.contains(clipId) {
            selectedClipIds.remove(clipId)
        } else {
            selectedClipIds.insert(clipId)
        }
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
        if let index = clips.firstIndex(where: { $0.id == clip.id }) {
            selectedIndex = index
        }
        self.pastingClipId = clip.id
        let forcePlainText = optionHeld || isPlainTextModeEnabled
        let transformation = activeTransformation
        let isTrusted = pasteInjector.eventPoster.isProcessTrusted()

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
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                self?.onClosePanel?()
                            }
                        }
                    }
                )
                self.pastingClipId = nil
                self.loadClips()
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
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                self?.onClosePanel?()
                            }
                        }
                    }
                )
                self.loadClips()
            } catch {
                print("[ConCopy] Failed to batch paste clips: \(error)")
            }
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

    public func assignClipToList(clip: ClipRecord, listId: UUID?) {
        do {
            _ = try databaseManager.assignClip(clipId: clip.id, toListId: listId)
            loadClips()
        } catch {
            print("[ConCopy] Failed to assign clip to list: \(error)")
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
}

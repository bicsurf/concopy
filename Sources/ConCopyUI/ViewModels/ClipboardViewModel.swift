import AppKit
import ApplicationServices
import Combine
import ConCopyCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
public final class ClipboardViewModel: ObservableObject {
    @Published public var clips: [ClipRecord] = []
    @Published public private(set) var hasMoreClips = false
    @Published public private(set) var isLoadingClips = false
    @Published public var cloudSyncStatus: CloudSyncStatus = .idle
    @Published public var isHistoryTemporary = false
    @Published public var snippetSaveError: String?

    // Collaborators
    public let selectionManager: BatchSelectionManager
    public let queueManager: PasteQueueManager
    public let searchCoordinator: SearchCoordinator

    private var loadVersion: UInt64 = 0
    private var appliedLoadVersion: UInt64?
    private var canActOnClips: Bool { appliedLoadVersion == loadVersion && !isLoadingClips }
    private struct SelectionMove {
        let offset: Int
        let extendSelection: Bool
    }
    private var pendingSelectionMoves: [SelectionMove] = []
    private var listLoadTask: Task<Void, Never>?
    private var snippetLoadTask: Task<Void, Never>?
    private var pendingActions: [UUID: Task<Void, Never>] = [:]
    private var thumbnailTasks = Set<UUID>()
    @Published private var thumbnailVersion: UInt64 = 0
    @Published public var lists: [ClipListRecord] = []

    // Proxy properties delegating to SearchCoordinator
    public var selectedListId: UUID? {
        get { searchCoordinator.selectedListId }
        set { searchCoordinator.selectedListId = newValue }
    }
    public var isFavoritesOnly: Bool {
        get { searchCoordinator.isFavoritesOnly }
        set { searchCoordinator.isFavoritesOnly = newValue }
    }
    public var selectedTypeFilter: ClipTypeFilter {
        get { searchCoordinator.selectedTypeFilter }
        set { searchCoordinator.selectedTypeFilter = newValue }
    }
    public var currentSortMode: ClipSortMode {
        get { searchCoordinator.currentSortMode }
        set { searchCoordinator.currentSortMode = newValue }
    }
    @Published public var searchQuery: String = "" {
        didSet {
            searchCoordinator.searchQuery = searchQuery
            if isSnippetsOnly {
                if selectedSnippetIndex >= filteredSnippets.count {
                    selectedSnippetIndex = max(0, filteredSnippets.count - 1)
                }
            } else {
                searchCoordinator.visibleLimit = 100
                loadClips()
            }
        }
    }

    // Proxy properties delegating to BatchSelectionManager
    @Published public var selectedClipIds: Set<UUID> = [] {
        didSet {
            if selectionManager.selectedClipIds != selectedClipIds {
                selectionManager.selectedClipIds = selectedClipIds
            }
        }
    }
    @Published public var selectedIndex: Int = 0 {
        didSet {
            selectionManager.selectedIndex = selectedIndex
        }
    }

    public var selectionAnchorId: UUID? {
        selectionManager.selectionAnchorId
    }

    public var selectedClipId: UUID? {
        get { selectionManager.selectedClipId(in: clips) }
        set {
            selectionManager.setSelectedClipId(newValue, in: clips)
            syncSelectionFromManager()
        }
    }

    public var isSelectionMode: Bool {
        selectionManager.isSelectionMode
    }

    // Proxy properties delegating to PasteQueueManager
    @Published public var pasteQueue: [ClipRecord] = []
    @Published public var pasteQueueOrder: PasteQueueOrder = .fifo {
        didSet { queueManager.pasteQueueOrder = pasteQueueOrder }
    }
    @Published public var isPasteQueueActive: Bool = false

    @Published public var isPlainTextModeEnabled: Bool = false
    @Published public var activeTransformation: TextTransformation = .none

    public var filteredClips: [ClipRecord] { clips }
    public var filteredSnippets: [SnippetRecord] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return snippets }
        return snippets.filter { snippet in
            snippet.shortcut.lowercased().contains(q) || snippet.content.lowercased().contains(q)
                || (snippet.title?.lowercased().contains(q) == true)
        }
    }

    @Published public var scrollTargetTopTrigger: UUID? = nil
    private var lastTopClipId: UUID? = nil
    private var lastTopClipUpdatedAt: Date? = nil
    @Published public var batchSeparator: BatchPasteSeparator = .newline
    @Published public var isSearchFocused: Bool = false
    @Published public var isQuickLookVisible: Bool = false
    @Published public var editingClip: ClipRecord? = nil
    @Published public var movingClip: ClipRecord? = nil
    @Published public var pastingClipId: UUID? = nil
    @Published public var copiedClipId: UUID? = nil
    @Published public var isAccessibilityTrusted: Bool = true
    @Published public var toastMessage: String? = nil
    @Published public var snippets: [SnippetRecord] = []
    @Published public var selectedSnippetIndex: Int = 0
    @Published public var isSnippetsOnly: Bool = false
    @Published public var isSnippetEditorPresented: Bool = false
    @Published public var editingSnippet: SnippetRecord? = nil

    @Published public var promptSnippet: SnippetRecord? = nil
    @Published public var promptSnippetVariables: [String] = []

    private var thumbnailCache = NSCache<NSUUID, NSImage>()
    private var webMetadataCache: [UUID: WebLinkMetadata] = [:]
    @Published public var webMetadataVersion: Int = 0
    private var copyFeedbackTask: Task<Void, Never>?

    public let databaseManager: DatabaseManager
    public let pasteInjector: PasteInjector
    public let appSettings: AppSettingsManager
    public let pasteboard: NSPasteboard
    public var onClosePanel: (() -> Void)?
    public var pasteTargetProcessIdentifier: (() -> pid_t?)?
    public var onPasteFailure: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onRetrySync: (() -> Void)?

    public init(
        databaseManager: DatabaseManager,
        pasteInjector: PasteInjector = PasteInjector(),
        appSettings: AppSettingsManager,
        pasteboard: NSPasteboard = .general,
        selectionManager: BatchSelectionManager? = nil,
        queueManager: PasteQueueManager? = nil,
        searchCoordinator: SearchCoordinator? = nil
    ) {
        self.databaseManager = databaseManager
        self.pasteInjector = pasteInjector
        self.appSettings = appSettings
        self.pasteboard = pasteboard
        self.selectionManager = selectionManager ?? BatchSelectionManager()
        self.queueManager = queueManager ?? PasteQueueManager()
        self.searchCoordinator = searchCoordinator ?? SearchCoordinator()

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

    deinit {
        copyFeedbackTask?.cancel()
        listLoadTask?.cancel()
        snippetLoadTask?.cancel()
        for task in pendingActions.values { task.cancel() }
    }

    private func syncSelectionFromManager() {
        self.selectedClipIds = selectionManager.selectedClipIds
        self.selectedIndex = selectionManager.selectedIndex
    }

    private func syncQueueFromManager() {
        self.pasteQueue = queueManager.pasteQueue
        self.isPasteQueueActive = queueManager.isPasteQueueActive
        self.pasteQueueOrder = queueManager.pasteQueueOrder
    }

    private func performUIAction(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        pendingActions[id] = Task { @MainActor [weak self] in
            await operation()
            self?.pendingActions.removeValue(forKey: id)
        }
    }

    public func waitForPendingLoads() async {
        while true {
            let version = loadVersion
            for task in Array(pendingActions.values) { await task.value }
            await listLoadTask?.value
            await snippetLoadTask?.value
            if pendingActions.isEmpty && version == loadVersion && !isLoadingClips { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    public func checkAccessibilityPermissions() {
        self.isAccessibilityTrusted = pasteInjector.eventPoster.isProcessTrusted()
    }

    public func openAccessibilitySettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func clearHistory(preserveFavorites: Bool = true) {
        performUIAction { [self] in
            do {
                let db = databaseManager
                _ = try await Task.detached(priority: .utility) {
                    try db.clearAllHistory(preserveFavorites: preserveFavorites)
                }.value
                loadClips()
            } catch {
                ConCopyLogger.storage.error("Failed to clear history: \(error.localizedDescription, privacy: .private)")
                showToast("Failed to clear history")
            }
        }
    }

    public func toggleQuickLook() {
        isQuickLookVisible.toggle()
    }

    public func saveEditedText(for clipId: UUID, newText: String) {
        performUIAction { [self] in
            do {
                let db = databaseManager
                let expirationMinutes = AppSettingsManager.shared.sensitiveClipExpirationMinutes
                try await Task.detached(priority: .utility) {
                    try db.updateTextContent(clipId: clipId, newPlainText: newText, expirationMinutes: expirationMinutes)
                }.value
                editingClip = nil
                loadClips()
            } catch {
                ConCopyLogger.storage.error("Failed to update text content: \(error.localizedDescription, privacy: .private)")
                showToast("Failed to save text")
            }
        }
    }

    public func loadLists() {
        listLoadTask?.cancel()
        let db = databaseManager
        listLoadTask = Task { [weak self] in
            do {
                let fetched = try await Task.detached(priority: .userInitiated) { try db.fetchLists() }.value
                guard !Task.isCancelled else { return }
                self?.lists = fetched
            } catch { self?.showToast("Could not load lists") }
        }
    }

    public func loadClips() {
        pendingSelectionMoves.removeAll()
        reloadClips()
    }

    private func reloadClips() {
        loadVersion &+= 1
        let version = loadVersion
        isLoadingClips = true

        searchCoordinator.executeSearch(
            databaseManager: databaseManager,
            onSuccess: { [weak self] fetched, hasMore, _ in
                guard let self, self.loadVersion == version else { return }
                let previousSelection = self.selectedClipId
                let isNewTop =
                    fetched.first.map { first in
                        first.id != self.lastTopClipId || self.lastTopClipUpdatedAt.map { first.updatedAt > $0 } == true
                    } ?? false
                self.clips = fetched
                self.appliedLoadVersion = version
                self.hasMoreClips = hasMore

                self.selectionManager.pruneInvalidIds(existingIds: Set(fetched.map(\.id)))
                self.syncSelectionFromManager()

                self.lastTopClipId = fetched.first?.id
                self.lastTopClipUpdatedAt = fetched.first?.updatedAt
                if isNewTop && !self.isSelectionMode && self.pendingSelectionMoves.isEmpty {
                    self.selectedIndex = 0
                    self.selectionManager.selectedIndex = 0
                    self.selectionManager.resetAnchor()
                    self.scrollTargetTopTrigger = UUID()
                } else if let previousSelection, let index = fetched.firstIndex(where: { $0.id == previousSelection }) {
                    self.selectedIndex = index
                    self.selectionManager.selectedIndex = index
                } else {
                    let idx = max(0, min(self.selectedIndex, fetched.count - 1))
                    self.selectedIndex = idx
                    self.selectionManager.selectedIndex = idx
                }
                self.isLoadingClips = false
                let moves = self.pendingSelectionMoves
                self.pendingSelectionMoves.removeAll()
                for move in moves {
                    self.moveSelection(by: move.offset, extendSelection: move.extendSelection)
                }
            },
            onFailure: { [weak self] _, _ in
                guard let self, self.loadVersion == version else { return }
                self.isLoadingClips = false
                self.pendingSelectionMoves.removeAll()
                self.showToast("Could not load clipboard history")
            }
        )
    }

    public func loadNextPage() {
        guard hasMoreClips, !isLoadingClips else { return }
        searchCoordinator.visibleLimit += 100
        loadClips()
    }

    public func selectMostRecentClip() {
        pendingSelectionMoves.removeAll()
        guard !clips.isEmpty else { return }
        selectedClipId = filteredClips.first?.id
        if !isSelectionMode {
            selectionManager.clearSelection()
            syncSelectionFromManager()
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
        searchCoordinator.visibleLimit = 100
        clearSelection()
        selectedListId = nil
        isFavoritesOnly = false
        isSnippetsOnly = false
        selectedTypeFilter = .all
        loadClips()
    }

    public func selectTypeFilter(_ filter: ClipTypeFilter) {
        guard selectedTypeFilter != filter else { return }
        selectedTypeFilter = filter
        searchCoordinator.visibleLimit = 100
        clearSelection()
        loadClips()
    }

    public func selectFavorites() {
        searchCoordinator.visibleLimit = 100
        clearSelection()
        selectedListId = nil
        isFavoritesOnly = true
        isSnippetsOnly = false
        loadClips()
    }

    public func selectSnippets() {
        searchCoordinator.visibleLimit = 100
        clearSelection()
        selectedListId = nil
        isFavoritesOnly = false
        isSnippetsOnly = true
        loadSnippets()
    }

    public func selectList(_ listId: UUID) {
        searchCoordinator.visibleLimit = 100
        clearSelection()
        selectedListId = listId
        isFavoritesOnly = false
        isSnippetsOnly = false
        if let list = lists.first(where: { $0.id == listId }) {
            currentSortMode = list.sortMode
        }
        loadClips()
    }

    public func createNewList(name: String) {
        performUIAction { [self] in
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                let db = databaseManager
                let list = try await Task.detached(priority: .utility) { try db.createList(name: name) }.value
                loadLists()
                selectList(list.id)
            } catch {
                ConCopyLogger.storage.error("Failed to create list: \(error.localizedDescription, privacy: .private)")
                showToast("Could not create list")
            }
        }
    }

    public func deleteList(_ listId: UUID, deleteContainedClips: Bool = false) {
        performUIAction { [self] in
            do {
                let db = databaseManager
                try await Task.detached(priority: .utility) {
                    try db.deleteList(listId: listId, deleteContainedClips: deleteContainedClips)
                }.value
                loadLists()
                if selectedListId == listId {
                    selectAllClips()
                }
            } catch {
                ConCopyLogger.storage.error("Failed to delete list: \(error.localizedDescription, privacy: .private)")
                showToast("Could not delete list")
            }
        }
    }

    public func toggleAutoStar(for listId: UUID) {
        performUIAction { [self] in
            do {
                if let list = lists.first(where: { $0.id == listId }) {
                    let willActivate = !list.isAutoStarActive
                    let db = databaseManager
                    try await Task.detached(priority: .utility) {
                        try db.setAutoStarList(listId: willActivate ? listId : nil)
                    }.value
                } else {
                    let db = databaseManager
                    try await Task.detached(priority: .utility) { try db.setAutoStarList(listId: listId) }.value
                }
                loadLists()
            } catch {
                ConCopyLogger.storage.error("Failed to set auto star list: \(error.localizedDescription, privacy: .private)")
                showToast("Could not update Auto-Star")
            }
        }
    }

    public func selectSingle(clipId: UUID) {
        pendingSelectionMoves.removeAll()
        selectionManager.selectSingle(clipId: clipId, in: clips)
        syncSelectionFromManager()
    }

    public func toggleSelection(for clip: ClipRecord) {
        toggleSelection(clipId: clip.id)
    }

    public func toggleSelection(clipId: UUID) {
        pendingSelectionMoves.removeAll()
        selectionManager.toggleSelection(clipId: clipId, in: clips)
        syncSelectionFromManager()
    }

    public func selectRange(to clip: ClipRecord) {
        selectRange(toClipId: clip.id)
    }

    public func selectRange(to clipId: UUID) {
        selectRange(toClipId: clipId)
    }

    public func selectRange(toClipId clipId: UUID) {
        pendingSelectionMoves.removeAll()
        selectionManager.selectRange(toClipId: clipId, in: clips)
        syncSelectionFromManager()
    }

    public func moveSelection(by offset: Int, extendSelection: Bool) {
        if isSnippetsOnly {
            let count = filteredSnippets.count
            guard count > 0 else { return }
            let newIndex = extendSelection
                ? max(0, min(count - 1, selectedSnippetIndex + offset))
                : wrappedSelectionIndex(selectedSnippetIndex, offset: offset, count: count)
            selectedSnippetIndex = newIndex
            return
        }

        if !pendingSelectionMoves.isEmpty {
            pendingSelectionMoves.append(SelectionMove(offset: offset, extendSelection: extendSelection))
            return
        }

        guard !clips.isEmpty, canActOnClips else { return }

        let proposedIndex = selectedIndex + offset
        if hasMoreClips && (proposedIndex >= clips.count || (proposedIndex < 0 && !extendSelection)) {
            pendingSelectionMoves.append(SelectionMove(offset: offset, extendSelection: extendSelection))
            searchCoordinator.visibleLimit = proposedIndex < 0 ? Int.max - 1 : searchCoordinator.visibleLimit + max(100, offset)
            reloadClips()
            return
        }

        if !extendSelection {
            selectionManager.selectedClipIds.removeAll()
            let newIndex = wrappedSelectionIndex(selectedIndex, offset: offset, count: clips.count)
            selectedIndex = newIndex
            selectionManager.selectedIndex = newIndex
            selectionManager.setAnchor(selectedClipId)
            syncSelectionFromManager()
            return
        }

        if selectionManager.selectionAnchorId == nil {
            selectionManager.setAnchor(selectedClipId)
        }

        let anchorIndex: Int
        if let anchorId = selectionManager.selectionAnchorId, let idx = clips.firstIndex(where: { $0.id == anchorId }) {
            anchorIndex = idx
        } else {
            anchorIndex = selectedIndex
            selectionManager.setAnchor(selectedClipId)
        }

        let targetIndex = max(0, min(clips.count - 1, selectedIndex + offset))
        selectedIndex = targetIndex
        selectionManager.selectedIndex = targetIndex

        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        var newSelection: Set<UUID> = []
        for idx in range {
            newSelection.insert(clips[idx].id)
        }
        selectionManager.selectedClipIds = newSelection
        syncSelectionFromManager()
    }

    private func wrappedSelectionIndex(_ index: Int, offset: Int, count: Int) -> Int {
        let target = (index % count + offset % count) % count
        return target < 0 ? target + count : target
    }

    public func moveSelectionUp(expandSelection: Bool = false) {
        moveSelection(by: -1, extendSelection: expandSelection)
    }

    public func moveSelectionDown(expandSelection: Bool = false) {
        moveSelection(by: 1, extendSelection: expandSelection)
    }

    public func clearSelection() {
        pendingSelectionMoves.removeAll()
        selectionManager.clearSelection(currentClipId: selectedClipId)
        syncSelectionFromManager()
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
        guard isSnippetsOnly || canActOnClips else { return }
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
        guard canActOnClips else { return }
        guard index >= 0 && index < clips.count else { return }
        selectedIndex = index
        selectionManager.selectedIndex = index
        paste(clip: clips[index], optionHeld: optionHeld)
    }

    public func handleRowClick(
        clip: ClipRecord,
        modifiers: NSEvent.ModifierFlags
    ) {
        handleRowClick(
            clip: clip,
            shiftHeld: modifiers.contains(.shift),
            commandHeld: modifiers.contains(.command),
            optionHeld: modifiers.contains(.option)
        )
    }

    public func handleRowClick(
        clip: ClipRecord,
        shiftHeld: Bool = false,
        commandHeld: Bool = false,
        optionHeld: Bool = false
    ) {
        if shiftHeld {
            if selectedClipId == nil {
                selectionManager.selectedClipIds.insert(clip.id)
                setSelectedClipIdDirect(clip.id)
                selectionManager.setAnchor(clip.id)
                syncSelectionFromManager()
            } else {
                selectRange(toClipId: clip.id)
            }
            return
        }

        if commandHeld {
            toggleSelection(clipId: clip.id)
            return
        }

        setSelectedClipIdDirect(clip.id)
        selectionManager.selectedClipIds.removeAll()
        selectionManager.setAnchor(clip.id)
        syncSelectionFromManager()

        paste(clip: clip, optionHeld: optionHeld)
    }

    private func setSelectedClipIdDirect(_ id: UUID) {
        if let idx = clips.firstIndex(where: { $0.id == id }) {
            selectedIndex = idx
            selectionManager.selectedIndex = idx
        }
    }

    public func copyClipToPasteboardWithoutClosing(clip: ClipRecord, optionHeld: Bool = false) {
        guard canActOnClips else { return }
        performUIAction { [self] in
            let forcePlainText = optionHeld || isPlainTextModeEnabled
            let transformation = activeTransformation
            do {
                try await pasteInjector.copyToPasteboard(
                    clip: clip,
                    databaseManager: databaseManager,
                    pasteboard: pasteboard,
                    forcePlainText: forcePlainText,
                    transformation: transformation
                )
                copyFeedbackTask?.cancel()
                copiedClipId = clip.id
                showToast("Copied to clipboard!")
                copyFeedbackTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 1_200_000_000)
                        try Task.checkCancellation()
                    } catch {
                        return
                    }

                    guard let self else { return }
                    if self.copiedClipId == clip.id {
                        self.copiedClipId = nil
                    }
                    self.copyFeedbackTask = nil
                }
                loadClips()
            } catch {
                ConCopyLogger.paste.error("Failed to copy clip: \(error.localizedDescription, privacy: .private)")
                showToast(error.localizedDescription)
            }
        }
    }

    public func paste(clip: ClipRecord, optionHeld: Bool = false, transformation: TextTransformation? = nil) {
        guard canActOnClips else { return }
        guard pastingClipId == nil else { return }
        if let index = clips.firstIndex(where: { $0.id == clip.id }) {
            selectedIndex = index
            selectionManager.selectedIndex = index
        }
        self.pastingClipId = clip.id
        let effectiveTransformation = transformation ?? activeTransformation
        let forcePlainText = optionHeld || isPlainTextModeEnabled || effectiveTransformation != .none
        let isTrusted = pasteInjector.eventPoster.isProcessTrusted()
        let target = pasteTargetProcessIdentifier?()

        if !appSettings.isDirectPasteEnabled {
            performUIAction { [weak self] in
                guard let self else { return }
                do {
                    try await self.pasteInjector.copyToPasteboard(
                        clip: clip,
                        databaseManager: self.databaseManager,
                        pasteboard: self.pasteboard,
                        forcePlainText: forcePlainText,
                        transformation: effectiveTransformation
                    )
                    self.onClosePanel?()
                    self.pastingClipId = nil
                    self.loadClips()
                } catch {
                    self.pastingClipId = nil
                    ConCopyLogger.paste.error("Failed to copy clip: \(error.localizedDescription, privacy: .private)")
                    self.showToast(error.localizedDescription)
                }
            }
            return
        }

        performUIAction { [weak self] in
            guard let self else { return }
            do {
                if !isTrusted {
                    self.showToast("Copied to clipboard! Press ⌘V to paste.")
                }
                try await self.pasteInjector.paste(
                    clip: clip,
                    databaseManager: self.databaseManager,
                    pasteboard: self.pasteboard,
                    forcePlainText: forcePlainText,
                    transformation: effectiveTransformation,
                    targetProcessIdentifier: target,
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
                self.reportPasteFailure(error)
            }
        }
    }

    public func pasteSelectedBatch(mode: BatchPasteMode) {
        guard canActOnClips else { return }
        let orderedClips: [ClipRecord]
        if !selectedClipIds.isEmpty {
            orderedClips = clips.filter { selectedClipIds.contains($0.id) }
        } else if selectedIndex >= 0 && selectedIndex < clips.count {
            orderedClips = [clips[selectedIndex]]
        } else {
            return
        }

        let transformation = activeTransformation
        let isTrusted = pasteInjector.eventPoster.isProcessTrusted()
        let target = pasteTargetProcessIdentifier?()

        if !appSettings.isDirectPasteEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.pasteInjector.copyBatchToPasteboard(
                        clips: orderedClips,
                        mode: mode,
                        transformation: transformation,
                        databaseManager: self.databaseManager,
                        pasteboard: self.pasteboard
                    )
                    self.onClosePanel?()
                    self.clearSelection()
                    self.loadClips()
                } catch {
                    ConCopyLogger.paste.error("Failed to batch copy clips: \(error.localizedDescription, privacy: .private)")
                    self.showToast(error.localizedDescription)
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.pasteInjector.pasteBatch(
                    clips: orderedClips,
                    mode: mode,
                    transformation: transformation,
                    databaseManager: self.databaseManager,
                    pasteboard: self.pasteboard,
                    targetProcessIdentifier: target,
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
                    self.clearSelection()
                    self.loadClips()
                }
            } catch {
                self.reportPasteFailure(error)
            }
        }
    }

    // MARK: - Paste Queue Operations
    public func addToPasteQueue(clip: ClipRecord) {
        if queueManager.enqueue(clip) {
            syncQueueFromManager()
            showToast("Added to Paste \(pasteQueueOrder == .fifo ? "Queue" : "Stack") (\(pasteQueue.count))")
        }
    }

    public func addSelectedToPasteQueue() {
        let items: [ClipRecord]
        if !selectedClipIds.isEmpty {
            items = clips.filter { selectedClipIds.contains($0.id) }
        } else if selectedIndex >= 0 && selectedIndex < clips.count {
            items = [clips[selectedIndex]]
        } else {
            return
        }

        let countAdded = queueManager.enqueue(contentsOf: items)
        if countAdded > 0 || !queueManager.isEmpty {
            syncQueueFromManager()
            showToast("\(items.count) item(s) added to Paste \(pasteQueueOrder == .fifo ? "Queue" : "Stack") (\(pasteQueue.count))")
            clearSelection()
        }
    }

    public func clearPasteQueue() {
        queueManager.clear()
        syncQueueFromManager()
        showToast("Paste Queue cleared")
    }

    public func pasteNextFromQueue() {
        guard let nextClip = queueManager.dequeue() else {
            showToast("Paste Queue is empty")
            return
        }
        syncQueueFromManager()

        let isTrusted = pasteInjector.eventPoster.isProcessTrusted()
        let target = pasteTargetProcessIdentifier?()

        if !appSettings.isDirectPasteEnabled || !isTrusted {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.pasteInjector.copyToPasteboard(
                        clip: nextClip,
                        databaseManager: self.databaseManager,
                        pasteboard: self.pasteboard
                    )
                    self.showToast("Copied next item! \(self.pasteQueue.count) remaining. Press ⌘V to paste.")
                } catch {
                    self.reportPasteFailure(error)
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.pasteInjector.paste(
                    clip: nextClip,
                    databaseManager: self.databaseManager,
                    pasteboard: self.pasteboard,
                    forcePlainText: false,
                    transformation: .none,
                    targetProcessIdentifier: target,
                    beforeEventHook: { [weak self] in
                        self?.onClosePanel?()
                    }
                )
                self.showToast("Pasted! \(self.pasteQueue.count) remaining in \(self.pasteQueueOrder == .fifo ? "Queue" : "Stack")")
            } catch {
                self.reportPasteFailure(error)
            }
        }
    }

    public func copySelectedToPasteboard() {
        guard isSnippetsOnly || canActOnClips else { return }
        performUIAction { [self] in
            if isSnippetsOnly {
                if selectedSnippetIndex >= 0 && selectedSnippetIndex < filteredSnippets.count {
                    let snippet = filteredSnippets[selectedSnippetIndex]
                    pasteboard.clearContents()
                    pasteboard.setString("1", forType: PasteInjector.internalPasteMarker)
                    pasteboard.setString(snippet.content, forType: .string)
                    showToast("Snippet copied to clipboard!")
                    onClosePanel?()
                }
                return
            }

            if !selectedClipIds.isEmpty {
                let ordered = clips.filter { selectedClipIds.contains($0.id) }
                if !ordered.isEmpty {
                    do {
                        try await pasteInjector.copyBatchToPasteboard(
                            clips: ordered,
                            mode: .concatenated(separator: batchSeparator),
                            transformation: activeTransformation,
                            databaseManager: databaseManager,
                            pasteboard: pasteboard
                        )
                        showToast("Copied \(ordered.count) items to clipboard!")
                        onClosePanel?()
                        loadClips()
                    } catch {
                        ConCopyLogger.paste.error("Failed to copy batch to pasteboard: \(error.localizedDescription, privacy: .private)")
                        showToast(error.localizedDescription)
                    }
                    return
                }
            }

            if selectedIndex >= 0 && selectedIndex < clips.count {
                let clip = clips[selectedIndex]
                copyClipToPasteboard(clip: clip)
            }
        }
    }

    public func copyClipToPasteboard(clip: ClipRecord, transformation: TextTransformation? = nil) {
        guard canActOnClips else { return }
        let effectiveTransformation = transformation ?? activeTransformation
        let forcePlainText = isPlainTextModeEnabled || effectiveTransformation != .none
        performUIAction { [self] in
            do {
                try await pasteInjector.copyToPasteboard(
                    clip: clip,
                    databaseManager: databaseManager,
                    pasteboard: pasteboard,
                    forcePlainText: forcePlainText,
                    transformation: effectiveTransformation
                )
                showToast("Copied to clipboard!")
                onClosePanel?()
                loadClips()
            } catch {
                ConCopyLogger.paste.error("Failed to copy clip to pasteboard: \(error.localizedDescription, privacy: .private)")
                showToast(error.localizedDescription)
            }
        }
    }

    public func copyPlainText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString("1", forType: NSPasteboard.PasteboardType("com.local.ConCopy.internalPaste"))
        pasteboard.setString(text, forType: .string)
        showToast("Copied to clipboard!")
        onClosePanel?()
    }

    public func pasteAsFile(clip: ClipRecord, imageFormat: ImageExportFormat = .png) {
        guard canActOnClips else { return }
        let target = pasteTargetProcessIdentifier?()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.pasteInjector.pasteAsFile(
                    clip: clip,
                    imageFormat: imageFormat,
                    databaseManager: self.databaseManager,
                    pasteboard: self.pasteboard,
                    targetProcessIdentifier: target,
                    beforeEventHook: { [weak self] in
                        self?.onClosePanel?()
                    }
                )
                self.loadClips()
            } catch {
                self.reportPasteFailure(error)
            }
        }
    }

    private func reportPasteFailure(_ error: Error) {
        guard !(error is CancellationError), (error as? CocoaError)?.code != .userCancelled else { return }
        onPasteFailure?()
        showToast(error.localizedDescription, duration: 5)
    }

    public func toggleFavorite(clip: ClipRecord) {
        performUIAction { [self] in
            do {
                let db = databaseManager
                _ = try await Task.detached(priority: .utility) { try db.toggleFavorite(clipId: clip.id) }.value
                loadClips()
            } catch {
                ConCopyLogger.storage.error("Failed to toggle favorite: \(error.localizedDescription, privacy: .private)")
                showToast("Could not update favorite")
            }
        }
    }

    public func toggleFavoriteSelected() {
        performUIAction { [self] in
            if !selectedClipIds.isEmpty {
                for clipId in selectedClipIds {
                    let db = databaseManager
                    _ = try? await Task.detached(priority: .utility) { try db.toggleFavorite(clipId: clipId) }.value
                }
                loadClips()
                showToast("Favorites updated ★")
            } else if selectedIndex >= 0 && selectedIndex < clips.count {
                let clip = clips[selectedIndex]
                toggleFavorite(clip: clip)
                showToast(clip.isFavorite ? "Removed from Favorites" : "Added to Favorites ★")
            }
        }
    }

    public func promptMoveSelectedClipToList() {
        guard selectedIndex >= 0 && selectedIndex < clips.count else { return }
        let clip = clips[selectedIndex]
        self.movingClip = clip
    }

    public func assignClipToList(clip: ClipRecord, listId: UUID?) {
        performUIAction { [self] in
            do {
                let db = databaseManager
                _ = try await Task.detached(priority: .utility) { try db.assignClip(clipId: clip.id, toListId: listId) }.value
                loadClips()
            } catch {
                ConCopyLogger.storage.error("Failed to assign clip to list: \(error.localizedDescription, privacy: .private)")
                showToast("Could not move to list")
            }
        }
    }

    public func assignSelectedClipsToList(listId: UUID?) {
        performUIAction { [self] in
            for clipId in selectedClipIds {
                do {
                    let db = databaseManager
                    _ = try await Task.detached(priority: .utility) {
                        try db.assignClip(clipId: clipId, toListId: listId)
                    }.value
                } catch {
                    ConCopyLogger.storage.error("Failed to assign clip \(clipId, privacy: .public) to list: \(error.localizedDescription, privacy: .private)")
                }
            }
            loadClips()
        }
    }

    public func convertMovingClipToSnippet() {
        guard let clip = movingClip else { return }
        movingClip = nil
        createSnippetFromClip(clip)
    }

    public func assignMovingClipToAll() {
        performUIAction { [self] in
            guard let clip = movingClip else { return }
            if clip.isFavorite {
                let db = databaseManager
                _ = try? await Task.detached(priority: .utility) { try db.toggleFavorite(clipId: clip.id) }.value
            }
            assignClipToList(clip: clip, listId: nil)
            movingClip = nil
            showToast("Removed from all lists")
        }
    }

    public func assignMovingClip(toOptionIndex digit: Int) {
        guard let clip = movingClip else { return }
        if digit == 1 {
            let wasFav = clip.isFavorite
            toggleFavorite(clip: clip)
            movingClip = nil
            showToast(wasFav ? "Removed from Favorites" : "Added to Favorites ★")
        } else if digit == 2 {
            convertMovingClipToSnippet()
        } else {
            let listIndex = digit == 0 ? 7 : (digit - 3)
            if listIndex >= 0 && listIndex < lists.count {
                let list = lists[listIndex]
                assignClipToList(clip: clip, listId: list.id)
                movingClip = nil
                showToast("Moved to \"\(list.name)\"")
            }
        }
    }

    public func deleteClip(_ clip: ClipRecord) {
        performUIAction { [self] in
            do {
                let db = databaseManager
                try await Task.detached(priority: .utility) { try db.deleteClip(clipId: clip.id) }.value
                selectionManager.selectedClipIds.remove(clip.id)
                syncSelectionFromManager()
                loadClips()
            } catch {
                ConCopyLogger.storage.error("Failed to delete clip: \(error.localizedDescription, privacy: .private)")
                showToast("Could not delete clip")
            }
        }
    }

    // MARK: - Snippets Management
    public func loadSnippets() {
        snippetLoadTask?.cancel()
        let db = databaseManager
        snippetLoadTask = Task { [weak self] in
            do {
                let fetched = try await Task.detached(priority: .userInitiated) { try db.fetchSnippets() }.value
                guard !Task.isCancelled, let self else { return }
                self.snippets = fetched
                self.selectedSnippetIndex = max(0, min(self.selectedSnippetIndex, self.filteredSnippets.count - 1))
            } catch { self?.showToast("Could not load snippets") }
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

    @discardableResult
    public func saveSnippet(shortcut: String, content: String, title: String? = nil, existingId: UUID? = nil) async -> Bool {
        snippetSaveError = nil
        let trimmedShortcut = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShortcut.isEmpty, !content.isEmpty else {
            snippetSaveError = "Shortcut and content are required"
            return false
        }
        let snippet = SnippetRecord(
            id: existingId ?? UUID(),
            shortcut: trimmedShortcut,
            content: content,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title : nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        do {
            let db = databaseManager
            try await Task.detached(priority: .utility) { try db.saveSnippet(snippet) }.value
            loadSnippets()
            showToast("Snippet saved: \(snippet.shortcut)")
            return true
        } catch {
            ConCopyLogger.storage.error("Failed to save snippet: \(error.localizedDescription, privacy: .private)")
            snippetSaveError = "Could not save. Check whether this shortcut is already in use."
            return false
        }
    }

    public func deleteSnippet(_ snippet: SnippetRecord) {
        performUIAction { [self] in
            do {
                let db = databaseManager
                try await Task.detached(priority: .utility) { try db.deleteSnippet(id: snippet.id) }.value
                loadSnippets()
                showToast("Snippet deleted")
            } catch {
                ConCopyLogger.storage.error("Failed to delete snippet: \(error.localizedDescription, privacy: .private)")
                showToast("Could not delete snippet")
            }
        }
    }

    public func pasteSnippet(_ snippet: SnippetRecord) {
        let customVars = SnippetVariableResolver.extractCustomVariables(from: snippet.content)
        if !customVars.isEmpty {
            promptSnippetVariables = customVars
            promptSnippet = snippet
            return
        }

        let resolved = SnippetVariableResolver.resolve(
            template: snippet.content,
            clipboardContent: pasteboard.string(forType: .string)
        )
        pasteResolvedSnippetText(resolved)
    }

    public func pasteSnippetWithVariables(_ snippet: SnippetRecord, values: [String: String]) {
        let resolved = SnippetVariableResolver.resolve(
            template: snippet.content,
            clipboardContent: pasteboard.string(forType: .string),
            customVariables: values
        )
        promptSnippet = nil
        promptSnippetVariables = []
        pasteResolvedSnippetText(resolved)
    }

    private func pasteResolvedSnippetText(_ text: String) {
        let target = pasteTargetProcessIdentifier?()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await pasteInjector.pasteText(text, pasteboard: pasteboard, targetProcessIdentifier: target) { [weak self] willSend in
                    guard let self else { return }
                    if willSend { onClosePanel?() }
                    else {
                        showToast("Copied to clipboard! Press ⌘V to paste.")
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 450_000_000)
                            self?.onClosePanel?()
                        }
                    }
                }
            } catch {
                reportPasteFailure(error)
            }
        }
    }

    // MARK: - Image / File Thumbnail Helper
    public func imageThumbnail(for clip: ClipRecord) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: clip.id as NSUUID) { return cached }
        guard clip.primaryType == .image, thumbnailTasks.insert(clip.id).inserted else { return nil }
        let db = databaseManager
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { () -> Data? in
                autoreleasepool {
                    guard
                        let payload = try? db.fetchPayloads(for: clip.id).first(where: {
                            $0.utiType == "public.png" || $0.utiType == "public.tiff"
                        }),
                        let bytes = try? db.loadPayloadData(for: payload),
                        let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                        let image = CGImageSourceCreateThumbnailAtIndex(
                            source, 0,
                            [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceThumbnailMaxPixelSize: 96,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                            ] as CFDictionary)
                    else { return nil }
                    let rep = NSBitmapImageRep(cgImage: image)
                    return rep.representation(using: .png, properties: [:])
                }
            }.value
            guard let self else { return }
            self.thumbnailTasks.remove(clip.id)
            if let data, let image = NSImage(data: data) {
                self.thumbnailCache.setObject(image, forKey: clip.id as NSUUID)
                self.thumbnailVersion &+= 1
            }
        }
        return nil
    }

    public func fileIcon(for clip: ClipRecord) -> NSImage? {
        guard clip.primaryType == .file else { return nil }
        if let cached = thumbnailCache.object(forKey: clip.id as NSUUID) { return cached }
        if thumbnailTasks.insert(clip.id).inserted {
            let db = databaseManager
            Task { [weak self] in
                let iconData = await Task.detached(priority: .utility) { () -> Data? in
                    guard let url = try? db.fileURLs(for: clip.id).first else { return nil }
                    return autoreleasepool { NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation }
                }.value
                guard let self else { return }
                self.thumbnailTasks.remove(clip.id)
                if let iconData, let icon = NSImage(data: iconData) {
                    self.thumbnailCache.setObject(icon, forKey: clip.id as NSUUID)
                    self.thumbnailVersion &+= 1
                }
            }
        }
        return NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
    }

    public func appIcon(for clip: ClipRecord) -> NSImage? {
        AppIconProvider.shared.icon(for: clip.sourceAppBundleId)
    }

    public func linkMetadata(for clip: ClipRecord) -> WebLinkMetadata? {
        guard clip.primaryType == .url, let urlString = clip.plainText else { return nil }
        if let cached = webMetadataCache[clip.id] { return cached }
        if thumbnailTasks.insert(clip.id).inserted {
            Task { [weak self] in
                let meta = await WebMetadataFetcher.shared.fetchMetadata(for: urlString)
                guard let self else { return }
                self.thumbnailTasks.remove(clip.id)
                if let meta {
                    self.webMetadataCache[clip.id] = meta
                    self.webMetadataVersion &+= 1
                }
            }
        }
        return nil
    }
}

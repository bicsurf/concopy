import Foundation
import ConCopyCore

/// Coordinates batch and single item selection state for clips.
@MainActor
public final class BatchSelectionManager: ObservableObject {
    @Published public var selectedClipIds: Set<UUID> = []
    @Published public var selectedIndex: Int = 0
    public private(set) var selectionAnchorId: UUID? = nil

    public init(selectedClipIds: Set<UUID> = [], selectedIndex: Int = 0, selectionAnchorId: UUID? = nil) {
        self.selectedClipIds = selectedClipIds
        self.selectedIndex = selectedIndex
        self.selectionAnchorId = selectionAnchorId
    }

    public var isSelectionMode: Bool {
        !selectedClipIds.isEmpty
    }

    public func selectedClipId(in clips: [ClipRecord]) -> UUID? {
        guard selectedIndex >= 0 && selectedIndex < clips.count else { return nil }
        return clips[selectedIndex].id
    }

    public func setSelectedClipId(_ id: UUID?, in clips: [ClipRecord]) {
        guard let id = id, let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = idx
    }

    public func selectSingle(clipId: UUID, in clips: [ClipRecord]) {
        selectedClipIds.removeAll()
        setSelectedClipId(clipId, in: clips)
        selectionAnchorId = clipId
    }

    public func toggleSelection(clipId: UUID, in clips: [ClipRecord]) {
        if selectedClipIds.contains(clipId) {
            selectedClipIds.remove(clipId)
        } else {
            selectedClipIds.insert(clipId)
        }
        setSelectedClipId(clipId, in: clips)
        selectionAnchorId = clipId
    }

    public func selectRange(toClipId clipId: UUID, in clips: [ClipRecord]) {
        guard !clips.isEmpty else { return }

        let currentSelectedId = selectedClipId(in: clips)
        let anchorId = selectionAnchorId ?? currentSelectedId
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
        setSelectedClipId(clipId, in: clips)
        if selectionAnchorId == nil {
            selectionAnchorId = clips[startIndex].id
        }
    }

    public func clearSelection(currentClipId: UUID? = nil) {
        selectedClipIds.removeAll()
        selectionAnchorId = currentClipId
    }

    public func pruneInvalidIds(existingIds: Set<UUID>) {
        selectedClipIds.formIntersection(existingIds)
        if let anchor = selectionAnchorId, !existingIds.contains(anchor) {
            selectionAnchorId = nil
        }
    }

    public func resetAnchor() {
        selectionAnchorId = nil
    }

    public func setAnchor(_ id: UUID?) {
        selectionAnchorId = id
    }
}

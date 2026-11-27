import Foundation
import ConCopyCore

/// Coordinates sequential paste queue / stack operations (FIFO vs LIFO).
@MainActor
public final class PasteQueueManager: ObservableObject {
    @Published public var pasteQueue: [ClipRecord] = []
    @Published public var pasteQueueOrder: PasteQueueOrder = .fifo
    @Published public var isPasteQueueActive: Bool = false

    public init(pasteQueue: [ClipRecord] = [], pasteQueueOrder: PasteQueueOrder = .fifo) {
        self.pasteQueue = pasteQueue
        self.pasteQueueOrder = pasteQueueOrder
        self.isPasteQueueActive = !pasteQueue.isEmpty
    }

    public var count: Int {
        pasteQueue.count
    }

    public var isEmpty: Bool {
        pasteQueue.isEmpty
    }

    @discardableResult
    public func enqueue(_ clip: ClipRecord) -> Bool {
        if !pasteQueue.contains(where: { $0.id == clip.id }) {
            pasteQueue.append(clip)
            isPasteQueueActive = true
            return true
        }
        return false
    }

    @discardableResult
    public func enqueue(contentsOf clips: [ClipRecord]) -> Int {
        var addedCount = 0
        for clip in clips {
            if !pasteQueue.contains(where: { $0.id == clip.id }) {
                pasteQueue.append(clip)
                addedCount += 1
            }
        }
        if !pasteQueue.isEmpty {
            isPasteQueueActive = true
        }
        return addedCount
    }

    public func dequeue() -> ClipRecord? {
        guard !pasteQueue.isEmpty else { return nil }
        let clip: ClipRecord
        if pasteQueueOrder == .fifo {
            clip = pasteQueue.removeFirst()
        } else {
            clip = pasteQueue.removeLast()
        }
        if pasteQueue.isEmpty {
            isPasteQueueActive = false
        }
        return clip
    }

    public func clear() {
        pasteQueue.removeAll()
        isPasteQueueActive = false
    }
}

import AppKit

/// One slot per pasteboard, shared by all injector instances and held across suspension points.
@MainActor
internal final class PasteOperationCoordinator {
    static let shared = PasteOperationCoordinator()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var active: [String: UUID] = [:]
    private var waiters: [String: [Waiter]] = [:]

    func acquire(_ pasteboard: NSPasteboard) async throws -> UUID {
        try Task.checkCancellation()
        let key = pasteboard.name.rawValue
        let id = UUID()
        if active[key] == nil {
            active[key] = id
            return id
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[key, default: []].append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id, key: key) }
        }
        do { try Task.checkCancellation() }
        catch { release(pasteboard, id: id); throw error }
        return id
    }

    func release(_ pasteboard: NSPasteboard, id: UUID) {
        let key = pasteboard.name.rawValue
        guard active[key] == id else { return }
        if var queued = waiters[key], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[key] = queued.isEmpty ? nil : queued
            active[key] = next.id
            next.continuation.resume()
        } else { active.removeValue(forKey: key) }
    }

    private func cancel(_ id: UUID, key: String) {
        guard var queued = waiters[key], let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let cancelled = queued.remove(at: index)
        waiters[key] = queued.isEmpty ? nil : queued
        cancelled.continuation.resume(throwing: CancellationError())
    }
}

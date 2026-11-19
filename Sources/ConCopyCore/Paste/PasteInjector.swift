import AppKit
import ApplicationServices
import Foundation

public protocol CGEventPosting: Sendable {
    func isProcessTrusted() -> Bool
    func postCommandV() -> Bool
    func postTab() -> Bool
}

public enum PasteInjectionError: LocalizedError {
    case eventFailed
    public var errorDescription: String? {
        "Automatic paste failed. The content is copied; paste it manually with ⌘V."
    }
}

public struct PasteResult: Sendable {
    public let eventSent: Bool
    public let usageRecorded: Bool
}

public struct SystemCGEventPoster: CGEventPosting {
    public init() {}

    public func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func postCommandV() -> Bool {
        guard isProcessTrusted() else {
            print("[ConCopy] Accessibility permissions not granted for CGEvent injection")
            return false
        }

        let keyCode: CGKeyCode = 0x09  // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("[ConCopy] Failed to create CGEventSource")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            print("[ConCopy] Failed to create CGEvent")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    public func postTab() -> Bool {
        guard isProcessTrusted() else {
            print("[ConCopy] Accessibility permissions not granted for CGEvent injection")
            return false
        }

        let keyCode: CGKeyCode = 0x30  // kVK_Tab
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

public struct PasteInjector: Sendable {
    public static let internalPasteMarker = NSPasteboard.PasteboardType("com.local.ConCopy.internalPaste")

    public let eventPoster: any CGEventPosting
    public let fileExporter: FilePasteExporter
    private let frontmostProcessIdentifier: @MainActor @Sendable () -> pid_t?

    public init(
        eventPoster: any CGEventPosting = SystemCGEventPoster(),
        fileExporter: FilePasteExporter = FilePasteExporter(),
        frontmostProcessIdentifier: @escaping @MainActor @Sendable () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        self.eventPoster = eventPoster
        self.fileExporter = fileExporter
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
    }

    public func preparePasteboard(
        for clip: ClipRecord, payloads: [ClipPayloadRecord], databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general, forcePlainText: Bool = false,
        transformation: TextTransformation = .none
    ) throws {
        var representations: [String: Data] = [:]
        for payload in payloads { representations[payload.utiType] = try databaseManager.loadPayloadData(for: payload) }
        writePrepared(
            clip: clip, representations: representations, pasteboard: pasteboard,
            forcePlainText: forcePlainText, transformation: transformation)
    }

    private func writePrepared(
        clip: ClipRecord, representations: [String: Data], pasteboard: NSPasteboard,
        forcePlainText: Bool, transformation: TextTransformation = .none
    ) {
        pasteboard.clearContents()
        pasteboard.setString("1", forType: Self.internalPasteMarker)
        if forcePlainText || transformation != .none {
            pasteboard.setString(TextTransformer.apply(transformation, to: clip.plainText ?? ""), forType: .string)
        } else if clip.primaryType == .file, !FileURLRepresentation.urls(in: representations).isEmpty {
            pasteboard.writeObjects(FileURLRepresentation.urls(in: representations).map { $0 as NSURL })
        } else {
            for (uti, data) in representations where uti != FileURLRepresentation.multipleURLsUTI {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(uti))
            }
            if let text = clip.plainText, pasteboard.string(forType: .string) == nil {
                pasteboard.setString(text, forType: .string)
            }
        }
        // writeObjects can replace the item containing the marker.
        pasteboard.setString("1", forType: Self.internalPasteMarker)
    }

    @MainActor
    @discardableResult
    public func copyToPasteboard(
        clip: ClipRecord, databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general, forcePlainText: Bool = false,
        transformation: TextTransformation = .none
    ) async throws -> PasteResult {
        let slot = try await PasteOperationCoordinator.shared.acquire(pasteboard)
        defer { PasteOperationCoordinator.shared.release(pasteboard, id: slot) }
        let recorded = try await copyToPasteboard(clip: clip, databaseManager: databaseManager, pasteboard: pasteboard,
            forcePlainText: forcePlainText, transformation: transformation, countUsage: true)
        return PasteResult(eventSent: false, usageRecorded: recorded)
    }

    @MainActor
    private func copyToPasteboard(
        clip: ClipRecord, databaseManager: DatabaseManager, pasteboard: NSPasteboard,
        forcePlainText: Bool, transformation: TextTransformation, countUsage: Bool
    ) async throws -> Bool {
        let originalChangeCount = pasteboard.changeCount
        let prepared = try await Task.detached(priority: .userInitiated) {
            var representations: [String: Data] = [:]
            if forcePlainText || transformation != .none {
                representations["public.utf8-plain-text"] = Data(
                    TextTransformer.apply(transformation, to: clip.plainText ?? "").utf8)
            } else {
                for payload in try databaseManager.fetchPayloads(for: clip.id) {
                    representations[payload.utiType] = try databaseManager.loadPayloadData(for: payload)
                }
            }
            return representations
        }.value
        try Task.checkCancellation()
        guard pasteboard.changeCount == originalChangeCount else { throw CocoaError(.userCancelled) }
        writePrepared(
            clip: clip, representations: prepared, pasteboard: pasteboard,
            forcePlainText: false)
        if countUsage { return await recordUsageIfPossible([clip], databaseManager) }
        return true
    }

    private func recordUsageIfPossible(_ clips: [ClipRecord], _ databaseManager: DatabaseManager) async -> Bool {
        do {
            try await Task.detached(priority: .utility) {
                for clip in clips { _ = try databaseManager.recordPasteUsage(clipId: clip.id) }
            }.value
            return true
        } catch {
            // Clipboard/event effects have already happened and must never be reported as a failed paste.
            print("[ConCopy] Content transferred; usage count could not be updated: \(error)")
            return false
        }
    }

    @MainActor
    @discardableResult
    public func copyBatchToPasteboard(
        clips: [ClipRecord], mode: BatchPasteMode,
        transformation: TextTransformation = .none, databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general
    ) async throws -> PasteResult {
        let slot = try await PasteOperationCoordinator.shared.acquire(pasteboard)
        defer { PasteOperationCoordinator.shared.release(pasteboard, id: slot) }
        let recorded = try await copyBatchToPasteboard(clips: clips, mode: mode, transformation: transformation,
            databaseManager: databaseManager, pasteboard: pasteboard, countUsage: true)
        return PasteResult(eventSent: false, usageRecorded: recorded)
    }

    @MainActor
    private func copyBatchToPasteboard(
        clips: [ClipRecord], mode: BatchPasteMode, transformation: TextTransformation,
        databaseManager: DatabaseManager, pasteboard: NSPasteboard, countUsage: Bool
    ) async throws -> Bool {
        guard !clips.isEmpty else { return true }
        if clips.count == 1, let clip = clips.first {
            return try await copyToPasteboard(
                clip: clip, databaseManager: databaseManager, pasteboard: pasteboard, forcePlainText: false,
                transformation: transformation, countUsage: countUsage)
        }
        let originalChangeCount = pasteboard.changeCount
        let joinedText = await Task.detached(priority: .userInitiated) {
            let separator: String
            switch mode {
            case .concatenated(let value): separator = value.rawValue
            case .sequentialFormFields: separator = "\t"
            }
            return clips.map { TextTransformer.apply(transformation, to: $0.plainText ?? "") }.joined(
                separator: separator)
        }.value
        try Task.checkCancellation()
        guard pasteboard.changeCount == originalChangeCount else { throw CocoaError(.userCancelled) }
        pasteboard.clearContents()
        pasteboard.setString("1", forType: Self.internalPasteMarker)
        pasteboard.setString(joinedText, forType: .string)
        if countUsage { return await recordUsageIfPossible(clips, databaseManager) }
        return true
    }

    @MainActor
    private func validateDestination(_ target: pid_t?, allowingOwnProcess: Bool = false) throws {
        let current = frontmostProcessIdentifier()
        guard let target, current == target
            || (allowingOwnProcess && current == ProcessInfo.processInfo.processIdentifier)
        else { throw CocoaError(.userCancelled) }
    }

    @MainActor
    private func postPasteIfRequested(_ requested: Bool, target: pid_t?,
        pasteboard: NSPasteboard, changeCount: Int) throws
    {
        try Task.checkCancellation()
        guard pasteboard.changeCount == changeCount else { throw CocoaError(.userCancelled) }
        if requested {
            try validateDestination(target)
            guard eventPoster.isProcessTrusted(), eventPoster.postCommandV() else {
                throw PasteInjectionError.eventFailed
            }
        }
    }

    @MainActor
    private func clipboardConsumptionGracePeriod() async {
        // CGEvent posting has no read acknowledgement. Do not let the next queued request
        // replace the clipboard immediately; cancellation after posting must not skip this grace.
        await Task { @MainActor in try? await Task.sleep(nanoseconds: 50_000_000) }.value
    }

    @MainActor
    @discardableResult
    public func paste(
        clip: ClipRecord, databaseManager: DatabaseManager, pasteboard: NSPasteboard = .general,
        forcePlainText: Bool = false, transformation: TextTransformation = .none,
        targetProcessIdentifier: pid_t? = nil,
        beforeEventHook: (() -> Void)? = nil
    ) async throws -> PasteResult {
        let target = targetProcessIdentifier ?? frontmostProcessIdentifier()
        let shouldInject = eventPoster.isProcessTrusted()
        let slot = try await PasteOperationCoordinator.shared.acquire(pasteboard)
        defer { PasteOperationCoordinator.shared.release(pasteboard, id: slot) }
        if shouldInject { try validateDestination(target, allowingOwnProcess: true) }
        _ = try await copyToPasteboard(
            clip: clip, databaseManager: databaseManager, pasteboard: pasteboard,
            forcePlainText: forcePlainText, transformation: transformation, countUsage: false)
        let changeCount = pasteboard.changeCount
        if shouldInject { try validateDestination(target, allowingOwnProcess: true) }
        beforeEventHook?()
        try await Task.sleep(nanoseconds: 80_000_000)
        try postPasteIfRequested(shouldInject, target: target, pasteboard: pasteboard, changeCount: changeCount)
        if shouldInject { await clipboardConsumptionGracePeriod() }
        return PasteResult(eventSent: shouldInject, usageRecorded: await recordUsageIfPossible([clip], databaseManager))
    }

    @MainActor
    @discardableResult
    public func pasteAsFile(
        clip: ClipRecord, imageFormat: ImageExportFormat = .png,
        databaseManager: DatabaseManager, pasteboard: NSPasteboard = .general,
        targetProcessIdentifier: pid_t? = nil,
        beforeEventHook: (() -> Void)? = nil
    ) async throws -> PasteResult {
        let target = targetProcessIdentifier ?? frontmostProcessIdentifier()
        let shouldInject = eventPoster.isProcessTrusted()
        let slot = try await PasteOperationCoordinator.shared.acquire(pasteboard)
        defer { PasteOperationCoordinator.shared.release(pasteboard, id: slot) }
        if shouldInject { try validateDestination(target, allowingOwnProcess: true) }
        let originalChangeCount = pasteboard.changeCount
        let exporter = fileExporter
        let fileURL = try await Task.detached(priority: .userInitiated) {
            if clip.primaryType == .image,
                let payload = try databaseManager.fetchPayloads(for: clip.id).first(where: {
                    $0.utiType == "public.png" || $0.utiType == "public.tiff"
                })
            {
                return try exporter.exportImageAsFile(
                    imageData: databaseManager.loadPayloadData(for: payload),
                    format: imageFormat, preferredName: clip.customName)
            }
            return try exporter.exportTextAsFile(clip.plainText ?? "", preferredName: clip.customName)
        }.value
        try Task.checkCancellation()
        guard pasteboard.changeCount == originalChangeCount else { throw CocoaError(.userCancelled) }
        if shouldInject { try validateDestination(target, allowingOwnProcess: true) }
        pasteboard.clearContents()
        pasteboard.setString("1", forType: Self.internalPasteMarker)
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.setString("1", forType: Self.internalPasteMarker)
        let changeCount = pasteboard.changeCount
        beforeEventHook?()
        try await Task.sleep(nanoseconds: 80_000_000)
        try postPasteIfRequested(shouldInject, target: target, pasteboard: pasteboard, changeCount: changeCount)
        if shouldInject { await clipboardConsumptionGracePeriod() }
        return PasteResult(eventSent: shouldInject, usageRecorded: await recordUsageIfPossible([clip], databaseManager))
    }

    @MainActor
    @discardableResult
    public func pasteBatch(
        clips: [ClipRecord], mode: BatchPasteMode,
        transformation: TextTransformation = .none, databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general, targetProcessIdentifier: pid_t? = nil,
        beforeEventHook: (() -> Void)? = nil
    ) async throws -> PasteResult {
        guard !clips.isEmpty else { return PasteResult(eventSent: false, usageRecorded: true) }
        let targetPID = targetProcessIdentifier ?? frontmostProcessIdentifier()
        let shouldInject = eventPoster.isProcessTrusted()
        let slot = try await PasteOperationCoordinator.shared.acquire(pasteboard)
        defer { PasteOperationCoordinator.shared.release(pasteboard, id: slot) }
        if shouldInject { try validateDestination(targetPID, allowingOwnProcess: true) }
        var changeCount = pasteboard.changeCount
        if case .sequentialFormFields(let delayMs) = mode, shouldInject {
            var recordedAll = true
            let values = await Task.detached(priority: .userInitiated) {
                clips.map { TextTransformer.apply(transformation, to: $0.plainText ?? "") }
            }.value
            try validateDestination(targetPID, allowingOwnProcess: true)
            beforeEventHook?()
            try await Task.sleep(nanoseconds: 80_000_000)
            let delay = min(delayMs, 5000) * 1_000_000
            for (index, value) in values.enumerated() {
                try Task.checkCancellation()
                try validateDestination(targetPID)
                guard pasteboard.changeCount == changeCount else { throw CocoaError(.userCancelled) }
                pasteboard.clearContents()
                pasteboard.setString("1", forType: Self.internalPasteMarker)
                pasteboard.setString(value, forType: .string)
                changeCount = pasteboard.changeCount
                try postPasteIfRequested(true, target: targetPID, pasteboard: pasteboard, changeCount: changeCount)
                await clipboardConsumptionGracePeriod()
                let recorded = await recordUsageIfPossible([clips[index]], databaseManager)
                recordedAll = recordedAll && recorded
                try Task.checkCancellation()
                if delay > 50_000_000 { try await Task.sleep(nanoseconds: delay - 50_000_000) }
                if index < values.count - 1 {
                    guard eventPoster.isProcessTrusted(), targetPID == frontmostProcessIdentifier(),
                        pasteboard.changeCount == changeCount else {
                        throw CocoaError(.userCancelled)
                    }
                    guard eventPoster.postTab() else { throw PasteInjectionError.eventFailed }
                    try await Task.sleep(nanoseconds: max(delay, 20_000_000))
                }
            }
            return PasteResult(eventSent: true, usageRecorded: recordedAll)
        } else {
            _ = try await copyBatchToPasteboard(
                clips: clips, mode: mode, transformation: transformation,
                databaseManager: databaseManager, pasteboard: pasteboard, countUsage: false)
            changeCount = pasteboard.changeCount
            if shouldInject { try validateDestination(targetPID, allowingOwnProcess: true) }
            beforeEventHook?()
            try await Task.sleep(nanoseconds: 80_000_000)
            try postPasteIfRequested(shouldInject, target: targetPID, pasteboard: pasteboard, changeCount: changeCount)
            if shouldInject { await clipboardConsumptionGracePeriod() }
            return PasteResult(eventSent: shouldInject, usageRecorded: await recordUsageIfPossible(clips, databaseManager))
        }
    }

    @MainActor
    @discardableResult
    public func pasteText(_ text: String, pasteboard: NSPasteboard = .general,
        targetProcessIdentifier: pid_t? = nil,
        beforeEventHook: ((_ willSendEvent: Bool) -> Void)? = nil) async throws -> PasteResult {
        let target = targetProcessIdentifier ?? frontmostProcessIdentifier()
        let shouldInject = eventPoster.isProcessTrusted()
        let slot = try await PasteOperationCoordinator.shared.acquire(pasteboard)
        defer { PasteOperationCoordinator.shared.release(pasteboard, id: slot) }
        if shouldInject { try validateDestination(target, allowingOwnProcess: true) }
        try Task.checkCancellation()
        pasteboard.clearContents()
        pasteboard.setString("1", forType: Self.internalPasteMarker)
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount
        beforeEventHook?(shouldInject)
        try await Task.sleep(nanoseconds: 80_000_000)
        try postPasteIfRequested(shouldInject, target: target, pasteboard: pasteboard, changeCount: changeCount)
        if shouldInject { await clipboardConsumptionGracePeriod() }
        return PasteResult(eventSent: shouldInject, usageRecorded: true)
    }
}

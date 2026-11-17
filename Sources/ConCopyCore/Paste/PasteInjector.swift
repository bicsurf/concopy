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
        let recorded = try await copyToPasteboard(clip: clip, databaseManager: databaseManager, pasteboard: pasteboard,
            forcePlainText: forcePlainText, transformation: transformation, countUsage: true)
        return PasteResult(eventSent: false, usageRecorded: recorded)
    }

    @MainActor
    private func copyToPasteboard(
        clip: ClipRecord, databaseManager: DatabaseManager, pasteboard: NSPasteboard,
        forcePlainText: Bool, transformation: TextTransformation, countUsage: Bool
    ) async throws -> Bool {
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
        pasteboard.clearContents()
        pasteboard.setString("1", forType: Self.internalPasteMarker)
        pasteboard.setString(joinedText, forType: .string)
        if countUsage { return await recordUsageIfPossible(clips, databaseManager) }
        return true
    }

    @MainActor
    private func postPasteIfRequested(_ requested: Bool) throws {
        if requested {
            guard eventPoster.isProcessTrusted(), eventPoster.postCommandV() else {
                throw PasteInjectionError.eventFailed
            }
        }
    }

    @MainActor
    @discardableResult
    public func paste(
        clip: ClipRecord, databaseManager: DatabaseManager, pasteboard: NSPasteboard = .general,
        forcePlainText: Bool = false, transformation: TextTransformation = .none,
        beforeEventHook: (() -> Void)? = nil
    ) async throws -> PasteResult {
        let shouldInject = eventPoster.isProcessTrusted()
        _ = try await copyToPasteboard(
            clip: clip, databaseManager: databaseManager, pasteboard: pasteboard,
            forcePlainText: forcePlainText, transformation: transformation, countUsage: false)
        beforeEventHook?()
        try await Task.sleep(nanoseconds: 80_000_000)
        try postPasteIfRequested(shouldInject)
        return PasteResult(eventSent: shouldInject, usageRecorded: await recordUsageIfPossible([clip], databaseManager))
    }

    @MainActor
    @discardableResult
    public func pasteAsFile(
        clip: ClipRecord, imageFormat: ImageExportFormat = .png,
        databaseManager: DatabaseManager, pasteboard: NSPasteboard = .general,
        beforeEventHook: (() -> Void)? = nil
    ) async throws -> PasteResult {
        let shouldInject = eventPoster.isProcessTrusted()
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
        pasteboard.clearContents()
        pasteboard.setString("1", forType: Self.internalPasteMarker)
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.setString("1", forType: Self.internalPasteMarker)
        beforeEventHook?()
        try await Task.sleep(nanoseconds: 80_000_000)
        try postPasteIfRequested(shouldInject)
        return PasteResult(eventSent: shouldInject, usageRecorded: await recordUsageIfPossible([clip], databaseManager))
    }

    @MainActor
    @discardableResult
    public func pasteBatch(
        clips: [ClipRecord], mode: BatchPasteMode,
        transformation: TextTransformation = .none, databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general, beforeEventHook: (() -> Void)? = nil
    ) async throws -> PasteResult {
        guard !clips.isEmpty else { return PasteResult(eventSent: false, usageRecorded: true) }
        let targetPID = frontmostProcessIdentifier()
        if case .sequentialFormFields(let delayMs) = mode, eventPoster.isProcessTrusted() {
            var recordedAll = true
            let values = await Task.detached(priority: .userInitiated) {
                clips.map { TextTransformer.apply(transformation, to: $0.plainText ?? "") }
            }.value
            beforeEventHook?()
            try await Task.sleep(nanoseconds: 80_000_000)
            let delay = min(delayMs, 5000) * 1_000_000
            for (index, value) in values.enumerated() {
                try Task.checkCancellation()
                guard eventPoster.isProcessTrusted(),
                    targetPID == frontmostProcessIdentifier()
                else {
                    throw CocoaError(.userCancelled)
                }
                pasteboard.clearContents()
                pasteboard.setString("1", forType: Self.internalPasteMarker)
                pasteboard.setString(value, forType: .string)
                guard eventPoster.postCommandV() else { throw PasteInjectionError.eventFailed }
                let recorded = await recordUsageIfPossible([clips[index]], databaseManager)
                recordedAll = recordedAll && recorded
                // Give the destination time to consume the clipboard before replacing its content.
                try await Task.sleep(nanoseconds: max(delay, 50_000_000))
                if index < values.count - 1 {
                    guard eventPoster.isProcessTrusted(), targetPID == frontmostProcessIdentifier() else {
                        throw CocoaError(.userCancelled)
                    }
                    guard eventPoster.postTab() else { throw PasteInjectionError.eventFailed }
                    try await Task.sleep(nanoseconds: max(delay, 20_000_000))
                }
            }
            return PasteResult(eventSent: true, usageRecorded: recordedAll)
        } else {
            let shouldInject = eventPoster.isProcessTrusted()
            _ = try await copyBatchToPasteboard(
                clips: clips, mode: mode, transformation: transformation,
                databaseManager: databaseManager, pasteboard: pasteboard, countUsage: false)
            beforeEventHook?()
            try await Task.sleep(nanoseconds: 80_000_000)
            try postPasteIfRequested(shouldInject)
            return PasteResult(eventSent: shouldInject, usageRecorded: await recordUsageIfPossible(clips, databaseManager))
        }
    }

    @MainActor
    @discardableResult
    public func pasteText(_ text: String, pasteboard: NSPasteboard = .general,
        beforeEventHook: ((_ willSendEvent: Bool) -> Void)? = nil) async throws -> PasteResult {
        let shouldInject = eventPoster.isProcessTrusted()
        try Task.checkCancellation()
        pasteboard.clearContents()
        pasteboard.setString("1", forType: Self.internalPasteMarker)
        pasteboard.setString(text, forType: .string)
        beforeEventHook?(shouldInject)
        try await Task.sleep(nanoseconds: 80_000_000)
        try postPasteIfRequested(shouldInject)
        return PasteResult(eventSent: shouldInject, usageRecorded: true)
    }
}

import AppKit
import ApplicationServices
import Foundation

public protocol CGEventPosting: Sendable {
    func isProcessTrusted() -> Bool
    func postCommandV() -> Bool
    func postTab() -> Bool
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

        let keyCode: CGKeyCode = 0x09 // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("[ConCopy] Failed to create CGEventSource")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
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

        let keyCode: CGKeyCode = 0x30 // kVK_Tab
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
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

    public init(
        eventPoster: any CGEventPosting = SystemCGEventPoster(),
        fileExporter: FilePasteExporter = FilePasteExporter()
    ) {
        self.eventPoster = eventPoster
        self.fileExporter = fileExporter
    }

    public func preparePasteboard(
        for clip: ClipRecord,
        payloads: [ClipPayloadRecord],
        databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general,
        forcePlainText: Bool = false,
        transformation: TextTransformation = .none
    ) throws {
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: Self.internalPasteMarker)

        if transformation != .none {
            let original = clip.plainText ?? ""
            let transformed = TextTransformer.apply(transformation, to: original)
            pasteboard.setString(transformed, forType: .string)
            return
        }

        if forcePlainText {
            let text = clip.plainText ?? ""
            pasteboard.setString(text, forType: .string)
        } else {
            if clip.primaryType == .file {
                if let filePayload = payloads.first(where: { $0.utiType == "public.file-url" }),
                   let data = try? databaseManager.loadPayloadData(for: filePayload),
                   let urlString = String(data: data, encoding: .utf8),
                   let fileURL = URL(string: urlString) {
                    pasteboard.writeObjects([fileURL as NSURL])
                } else if let text = clip.plainText {
                    pasteboard.setString(text, forType: .string)
                }
            } else if clip.primaryType == .image {
                if let imgPayload = payloads.first(where: { $0.utiType == "public.png" || $0.utiType == "public.tiff" }),
                   let data = try? databaseManager.loadPayloadData(for: imgPayload),
                   let image = NSImage(data: data) {
                    pasteboard.writeObjects([image])
                } else {
                    for payload in payloads {
                        let data = try databaseManager.loadPayloadData(for: payload)
                        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(payload.utiType))
                    }
                }
            } else if payloads.isEmpty {
                if let text = clip.plainText {
                    pasteboard.setString(text, forType: .string)
                }
            } else {
                for payload in payloads {
                    let data = try databaseManager.loadPayloadData(for: payload)
                    pasteboard.setData(data, forType: NSPasteboard.PasteboardType(payload.utiType))
                }
                if let text = clip.plainText, pasteboard.string(forType: .string) == nil {
                    pasteboard.setString(text, forType: .string)
                }
            }
        }
        // Assicura che il marcatore anti-loopback interno sia sempre presente
        pasteboard.setData(Data(), forType: Self.internalPasteMarker)
    }

    @MainActor
    public func copyToPasteboard(
        clip: ClipRecord,
        databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general,
        forcePlainText: Bool = false,
        transformation: TextTransformation = .none
    ) throws {
        let payloads = try databaseManager.fetchPayloads(forClipId: clip.id)
        try preparePasteboard(
            for: clip,
            payloads: payloads,
            databaseManager: databaseManager,
            pasteboard: pasteboard,
            forcePlainText: forcePlainText,
            transformation: transformation
        )
        _ = try databaseManager.recordPasteUsage(clipId: clip.id)
    }

    @MainActor
    public func copyBatchToPasteboard(
        clips: [ClipRecord],
        mode: BatchPasteMode,
        transformation: TextTransformation = .none,
        databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general
    ) throws {
        guard !clips.isEmpty else { return }

        let separatorString: String
        switch mode {
        case .concatenated(let separator):
            separatorString = separator.rawValue
        case .sequentialFormFields:
            separatorString = "\t"
        }

        let processedStrings = clips.map { clip -> String in
            let text = clip.plainText ?? ""
            return TextTransformer.apply(transformation, to: text)
        }
        let joinedText = processedStrings.joined(separator: separatorString)

        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: Self.internalPasteMarker)
        pasteboard.setString(joinedText, forType: .string)

        for clip in clips {
            _ = try databaseManager.recordPasteUsage(clipId: clip.id)
        }
    }

    @MainActor
    public func paste(
        clip: ClipRecord,
        databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general,
        forcePlainText: Bool = false,
        transformation: TextTransformation = .none,
        beforeEventHook: (() -> Void)? = nil
    ) async throws {
        let payloads = try databaseManager.fetchPayloads(forClipId: clip.id)
        try preparePasteboard(
            for: clip,
            payloads: payloads,
            databaseManager: databaseManager,
            pasteboard: pasteboard,
            forcePlainText: forcePlainText,
            transformation: transformation
        )

        _ = try databaseManager.recordPasteUsage(clipId: clip.id)

        beforeEventHook?()

        try await Task.sleep(nanoseconds: 80_000_000)

        if eventPoster.isProcessTrusted() {
            _ = eventPoster.postCommandV()
        }
    }

    @MainActor
    public func pasteAsFile(
        clip: ClipRecord,
        imageFormat: ImageExportFormat = .png,
        databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general,
        beforeEventHook: (() -> Void)? = nil
    ) async throws {
        let fileURL: URL

        if clip.primaryType == .image {
            let payloads = try databaseManager.fetchPayloads(forClipId: clip.id)
            let imagePayload = payloads.first { $0.utiType == "public.png" || $0.utiType == "public.tiff" }
            if let payload = imagePayload {
                let data = try databaseManager.loadPayloadData(for: payload)
                fileURL = try fileExporter.exportImageAsFile(
                    imageData: data,
                    format: imageFormat,
                    preferredName: clip.customName
                )
            } else {
                fileURL = try fileExporter.exportTextAsFile(
                    clip.plainText ?? "",
                    preferredName: clip.customName
                )
            }
        } else {
            fileURL = try fileExporter.exportTextAsFile(
                clip.plainText ?? "",
                preferredName: clip.customName
            )
        }

        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.setData(Data(), forType: Self.internalPasteMarker)

        _ = try databaseManager.recordPasteUsage(clipId: clip.id)

        beforeEventHook?()

        try await Task.sleep(nanoseconds: 80_000_000)

        if eventPoster.isProcessTrusted() {
            _ = eventPoster.postCommandV()
        }
    }

    @MainActor
    public func pasteBatch(
        clips: [ClipRecord],
        mode: BatchPasteMode,
        transformation: TextTransformation = .none,
        databaseManager: DatabaseManager,
        pasteboard: NSPasteboard = .general,
        beforeEventHook: (() -> Void)? = nil
    ) async throws {
        guard !clips.isEmpty else { return }

        // 1. Release panel & reactivate target application
        beforeEventHook?()

        // 2. Initial delay of at least 80ms for WindowServer context switch
        try await Task.sleep(nanoseconds: 80_000_000)

        // 3. Process combined text based on mode (newline, custom separator, or tab for form fields)
        let separatorString: String
        switch mode {
        case .concatenated(let separator):
            separatorString = separator.rawValue
        case .sequentialFormFields:
            separatorString = "\t"
        }

        let processedStrings = clips.map { clip -> String in
            let text = clip.plainText ?? ""
            return TextTransformer.apply(transformation, to: text)
        }
        let joinedText = processedStrings.joined(separator: separatorString)

        // 4. Write resulting combined string once to pasteboard
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: Self.internalPasteMarker)
        pasteboard.setString(joinedText, forType: .string)

        for clip in clips {
            _ = try databaseManager.recordPasteUsage(clipId: clip.id)
        }

        // 5. Additional 50ms buffer before sending the single Cmd+V CGEvent
        try await Task.sleep(nanoseconds: 50_000_000)

        if eventPoster.isProcessTrusted() {
            _ = eventPoster.postCommandV()
        }
    }
}

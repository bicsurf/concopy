import AppKit
import Foundation

public enum ImageExportFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case tiff

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        }
    }

    public var bitmapType: NSBitmapImageRep.FileType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }
}

public enum FilePasteExporterError: LocalizedError {
    case invalidImageData
    case imageConversionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Dati immagine non validi o formato non supportato."
        case .imageConversionFailed:
            return "Impossibile convertire l'immagine nel formato specificato."
        }
    }
}

public struct FilePasteExporter: Sendable {
    public let exportDirectoryURL: URL

    public static var defaultExportDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyExports", isDirectory: true)
    }

    public init(exportDirectoryURL: URL = defaultExportDirectoryURL) {
        self.exportDirectoryURL = exportDirectoryURL
    }

    public func exportTextAsFile(_ text: String, preferredName: String? = nil) throws -> URL {
        try ensureDirectoryExists()

        let baseName = sanitizeFilename(preferredName) ?? "clip_\(Date().timeIntervalSince1970)"
        let filename = "\(baseName).txt"
        let fileURL = exportDirectoryURL.appendingPathComponent(filename)

        let data = Data(text.utf8)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    public func exportImageAsFile(
        imageData: Data,
        format: ImageExportFormat,
        preferredName: String? = nil
    ) throws -> URL {
        try ensureDirectoryExists()

        guard let imageRep = NSBitmapImageRep(data: imageData) else {
            throw FilePasteExporterError.invalidImageData
        }

        let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg
            ? [.compressionFactor: 0.85]
            : [:]

        guard let convertedData = imageRep.representation(using: format.bitmapType, properties: properties) else {
            throw FilePasteExporterError.imageConversionFailed
        }

        let baseName = sanitizeFilename(preferredName) ?? "clip_\(Date().timeIntervalSince1970)"
        let filename = "\(baseName).\(format.fileExtension)"
        let fileURL = exportDirectoryURL.appendingPathComponent(filename)

        try convertedData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: exportDirectoryURL.path) {
            try FileManager.default.createDirectory(at: exportDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func sanitizeFilename(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\":<>")
        let cleaned = raw.components(separatedBy: invalidCharacters).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    }
}

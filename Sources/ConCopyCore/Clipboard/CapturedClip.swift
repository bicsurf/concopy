import CryptoKit
import Foundation

public struct CapturedClip: Sendable, Equatable {
    public let plainText: String?
    public let primaryType: ClipPrimaryType
    public let sourceAppBundleId: String?
    public let representations: [String: Data]

    public init(
        plainText: String? = nil,
        primaryType: ClipPrimaryType = .text,
        sourceAppBundleId: String? = nil,
        representations: [String: Data] = [:]
    ) {
        self.plainText = plainText
        self.primaryType = primaryType
        self.sourceAppBundleId = sourceAppBundleId
        self.representations = representations
    }

    /// Run on a background executor before persistence so OCR secrets cannot reach sync unclassified.
    public func recognizingImageText(
        using recognize: (Data) -> String? = ImageTextRecognizer.recognizeText(from:)
    ) -> CapturedClip {
        guard primaryType == .image,
              let data = representations["public.png"] ?? representations["public.tiff"],
              let text = autoreleasepool(invoking: { recognize(data) }), !text.isEmpty else { return self }
        let existing = plainText ?? ""
        let combined = existing.contains(text) ? existing : (existing.isEmpty ? text : existing + "\n" + text)
        return CapturedClip(plainText: combined, primaryType: primaryType,
                            sourceAppBundleId: sourceAppBundleId, representations: representations)
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ data: Data, domain: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(("ConCopy:" + domain + ":2\0").utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    internal func migratedContentHash(fallback: String) -> String {
        let hasFile = primaryType == .file && !FileURLRepresentation.urls(in: representations).isEmpty
        let hasImage = primaryType == .image && ["public.png", "public.tiff"].contains {
            representations[$0]?.isEmpty == false
        }
        return hasFile || hasImage ? computeContentHash() : fallback
    }

    public func computeContentHash() -> String {
        // Labels (image dimensions and file names) are not clipboard identity.
        if primaryType == .file {
            let urls = FileURLRepresentation.urls(in: representations)
            if !urls.isEmpty {
                return Self.hash(Data(urls.map { $0.standardizedFileURL.absoluteString }.joined(separator: "\n").utf8), domain: "file")
            }
        }
        if primaryType == .image {
            for uti in ["public.png", "public.tiff"] {
                if let data = representations[uti], !data.isEmpty { return Self.hash(data, domain: "image") }
            }
        }
        if let plainText, !plainText.isEmpty {
            let normalized = plainText.precomposedStringWithCanonicalMapping
            let digest = SHA256.hash(data: Data(normalized.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        let priorityUTIs = [
            "public.png",
            "public.tiff",
            "public.file-url",
            "public.rtf",
            "public.html",
            "public.url",
        ]

        for uti in priorityUTIs {
            if let data = representations[uti], !data.isEmpty {
                let digest = SHA256.hash(data: data)
                return digest.map { String(format: "%02x", $0) }.joined()
            }
        }

        var hasher = SHA256()
        for key in representations.keys.sorted() {
            if let data = representations[key] {
                hasher.update(data: Data(key.utf8))
                hasher.update(data: data)
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

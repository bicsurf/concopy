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

    public func computeContentHash() -> String {
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
            "public.url"
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

import ConCopyCore
import Foundation

struct ClipRowTextPresentation {
    let preview: String
    let accessibilityTitle: String

    init(plainText: String?, fallbackTitle: String, shouldMaskSensitive: Bool, isRevealed: Bool) {
        let text = plainText.map {
            shouldMaskSensitive && !isRevealed ? SensitiveDataDetector.maskSensitiveText($0) : $0
        }
        preview = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No preview available"
        // Mask before truncating: a long secret must still match the detector in full.
        accessibilityTitle = String((text ?? fallbackTitle).prefix(160))
    }
}

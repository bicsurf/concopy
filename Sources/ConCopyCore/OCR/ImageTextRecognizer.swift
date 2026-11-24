import CoreGraphics
import Foundation
import ImageIO
import Vision

public struct ImageTextRecognizer: Sendable {
    public static func recognizeText(from data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return recognizeText(from: cgImage)
    }

    public static func recognizeText(from cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let results = request.results else { return nil }
            let recognizedLines = results.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            let joined = recognizedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        } catch {
            return nil
        }
    }
}

import Foundation
import ImageIO

internal enum CompleteImageDecoder {
    private static let pngSignature: [UInt8] = [137,80,78,71,13,10,26,10]

    static func isPNG(_ data: Data) -> Bool { data.starts(with: pngSignature) }

    /// ImageIO accepts a PNG header without raster data; require complete chunks through IEND as well.
    static func hasCompletePNGChunks(_ data: Data) -> Bool {
        guard isPNG(data) else { return false }
        var offset = 8
        var hasHeader = false, hasPixels = false
        while data.count - offset >= 12 {
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
            guard length <= data.count - offset - 12 else { return false }
            let type = Array(data[(offset+4)..<(offset+8)])
            if !hasHeader {
                guard type == Array("IHDR".utf8), length == 13 else { return false }
                hasHeader = true
            }
            if type == Array("IDAT".utf8) { hasPixels = true }
            offset += length + 12
            if type == Array("IEND".utf8) { return hasHeader && hasPixels && length == 0 && offset == data.count }
        }
        return false
    }

    static func decode(_ data: Data) -> CGImage? {
        if isPNG(data), !hasCompletePNGChunks(data) { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary),
            let pixels = image.dataProvider?.data, CFDataGetLength(pixels) > 0 else { return nil }
        return image
    }
}

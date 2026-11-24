import Foundation

public struct RGBAColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = min(max(red, 0.0), 1.0)
        self.green = min(max(green, 0.0), 1.0)
        self.blue = min(max(blue, 0.0), 1.0)
        self.alpha = min(max(alpha, 0.0), 1.0)
    }

    public var hexString: String {
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        if alpha < 0.999 {
            let a = Int(round(alpha * 255))
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        } else {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }

    public var rgbString: String {
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        if alpha < 0.999 {
            let aFormatted = String(format: "%.2f", alpha)
            return "rgba(\(r), \(g), \(b), \(aFormatted))"
        } else {
            return "rgb(\(r), \(g), \(b))"
        }
    }

    public var hslString: String {
        let r = red
        let g = green
        let b = blue
        let maxVal = max(r, g, b)
        let minVal = min(r, g, b)
        let delta = maxVal - minVal

        var h: Double = 0
        var s: Double = 0
        let l: Double = (maxVal + minVal) / 2.0

        if delta != 0 {
            s = l > 0.5 ? delta / (2.0 - maxVal - minVal) : delta / (maxVal + minVal)
            if maxVal == r {
                h = ((g - b) / delta) + (g < b ? 6.0 : 0.0)
            } else if maxVal == g {
                h = ((b - r) / delta) + 2.0
            } else {
                h = ((r - g) / delta) + 4.0
            }
            h *= 60.0
        }

        let hInt = Int(round(h))
        let sInt = Int(round(s * 100))
        let lInt = Int(round(l * 100))

        if alpha < 0.999 {
            let aFormatted = String(format: "%.2f", alpha)
            return "hsla(\(hInt), \(sInt)%, \(lInt)%, \(aFormatted))"
        } else {
            return "hsl(\(hInt), \(sInt)%, \(lInt)%)"
        }
    }
}

public struct ColorParser: Sendable {
    public static func parse(_ text: String) -> RGBAColor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed.count <= 40 else { return nil }

        if let hexColor = parseHex(trimmed) {
            return hexColor
        }
        if let rgbColor = parseRGB(trimmed) {
            return rgbColor
        }
        if let hslColor = parseHSL(trimmed) {
            return hslColor
        }
        return nil
    }

    private static func parseHex(_ text: String) -> RGBAColor? {
        guard text.hasPrefix("#") else { return nil }
        let hex = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intVal = UInt64(hex, radix: 16) else { return nil }

        switch hex.count {
        case 3: // #RGB
            let r = Double((intVal >> 8) & 0xF) / 15.0
            let g = Double((intVal >> 4) & 0xF) / 15.0
            let b = Double(intVal & 0xF) / 15.0
            return RGBAColor(red: r, green: g, blue: b, alpha: 1.0)

        case 4: // #RGBA
            let r = Double((intVal >> 12) & 0xF) / 15.0
            let g = Double((intVal >> 8) & 0xF) / 15.0
            let b = Double((intVal >> 4) & 0xF) / 15.0
            let a = Double(intVal & 0xF) / 15.0
            return RGBAColor(red: r, green: g, blue: b, alpha: a)

        case 6: // #RRGGBB
            let r = Double((intVal >> 16) & 0xFF) / 255.0
            let g = Double((intVal >> 8) & 0xFF) / 255.0
            let b = Double(intVal & 0xFF) / 255.0
            return RGBAColor(red: r, green: g, blue: b, alpha: 1.0)

        case 8: // #RRGGBBAA
            let r = Double((intVal >> 24) & 0xFF) / 255.0
            let g = Double((intVal >> 16) & 0xFF) / 255.0
            let b = Double((intVal >> 8) & 0xFF) / 255.0
            let a = Double(intVal & 0xFF) / 255.0
            return RGBAColor(red: r, green: g, blue: b, alpha: a)

        default:
            return nil
        }
    }

    private static func parseRGB(_ text: String) -> RGBAColor? {
        let lower = text.lowercased()
        guard lower.hasPrefix("rgb(") || lower.hasPrefix("rgba(") else { return nil }
        guard lower.hasSuffix(")") else { return nil }

        let startIdx = lower.firstIndex(of: "(").map { lower.index(after: $0) }
        let endIdx = lower.lastIndex(of: ")")
        guard let start = startIdx, let end = endIdx, start < end else { return nil }

        let inner = String(lower[start..<end])
            .replacingOccurrences(of: "/", with: ",")
        let parts = inner.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count == 3 || parts.count == 4 else { return nil }

        guard let r = parseComponent(parts[0], maxValue: 255.0),
              let g = parseComponent(parts[1], maxValue: 255.0),
              let b = parseComponent(parts[2], maxValue: 255.0) else {
            return nil
        }

        let a: Double
        if parts.count == 4 {
            guard let alpha = parseAlpha(parts[3]) else { return nil }
            a = alpha
        } else {
            a = 1.0
        }

        return RGBAColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func parseHSL(_ text: String) -> RGBAColor? {
        let lower = text.lowercased()
        guard lower.hasPrefix("hsl(") || lower.hasPrefix("hsla(") else { return nil }
        guard lower.hasSuffix(")") else { return nil }

        let startIdx = lower.firstIndex(of: "(").map { lower.index(after: $0) }
        let endIdx = lower.lastIndex(of: ")")
        guard let start = startIdx, let end = endIdx, start < end else { return nil }

        let inner = String(lower[start..<end])
            .replacingOccurrences(of: "/", with: ",")
        let parts = inner.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count == 3 || parts.count == 4 else { return nil }

        guard let h = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
              let sStr = parsePercent(parts[1]),
              let lStr = parsePercent(parts[2]) else {
            return nil
        }

        let a: Double
        if parts.count == 4 {
            guard let alpha = parseAlpha(parts[3]) else { return nil }
            a = alpha
        } else {
            a = 1.0
        }

        let hNorm = (h.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)
        let (r, g, b) = hslToRGB(h: hNorm, s: sStr, l: lStr)
        return RGBAColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func parseComponent(_ str: String, maxValue: Double) -> Double? {
        if str.hasSuffix("%") {
            guard let val = Double(str.dropLast()) else { return nil }
            return Swift.min(Swift.max(val / 100.0, 0.0), 1.0)
        }
        guard let val = Double(str) else { return nil }
        return Swift.min(Swift.max(val / maxValue, 0.0), 1.0)
    }

    private static func parsePercent(_ str: String) -> Double? {
        if str.hasSuffix("%") {
            guard let val = Double(str.dropLast()) else { return nil }
            return Swift.min(Swift.max(val / 100.0, 0.0), 1.0)
        }
        guard let val = Double(str) else { return nil }
        return Swift.min(Swift.max(val > 1.0 ? val / 100.0 : val, 0.0), 1.0)
    }

    private static func parseAlpha(_ str: String) -> Double? {
        if str.hasSuffix("%") {
            guard let val = Double(str.dropLast()) else { return nil }
            return Swift.min(Swift.max(val / 100.0, 0.0), 1.0)
        }
        guard let val = Double(str) else { return nil }
        return Swift.min(Swift.max(val, 0.0), 1.0)
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        if s == 0 {
            return (l, l, l)
        }
        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let x = c * (1.0 - abs((h / 60.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = l - c / 2.0

        var rPrime = 0.0
        var gPrime = 0.0
        var bPrime = 0.0

        switch h {
        case 0..<60:
            (rPrime, gPrime, bPrime) = (c, x, 0)
        case 60..<120:
            (rPrime, gPrime, bPrime) = (x, c, 0)
        case 120..<180:
            (rPrime, gPrime, bPrime) = (0, c, x)
        case 180..<240:
            (rPrime, gPrime, bPrime) = (0, x, c)
        case 240..<300:
            (rPrime, gPrime, bPrime) = (x, 0, c)
        default:
            (rPrime, gPrime, bPrime) = (c, 0, x)
        }

        return (rPrime + m, gPrime + m, bPrime + m)
    }
}

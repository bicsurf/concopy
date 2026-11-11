import AppKit

public enum MenuBarIcon {
    /// Restituisce l'icona personalizzata per la barra dei menu di macOS (18x18 pt, template image).
    public static func create() -> NSImage {
        // 1. Override opzionale da bundle
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf") ?? Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let customImage = NSImage(contentsOf: url) {
            customImage.size = NSSize(width: 18, height: 18)
            customImage.isTemplate = true
            return customImage
        }

        // 2. Disegno vettoriale nativo ad alta risoluzione
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Coordinate e dimensioni scheda anteriore principale
            let frontWidth: CGFloat = 10.5
            let frontHeight: CGFloat = 13.0
            let frontX: CGFloat = 2.0
            let frontY: CGFloat = 2.0
            let frontRect = NSRect(x: frontX, y: frontY, width: frontWidth, height: frontHeight)
            let frontRadius: CGFloat = 2.4
            let frontPath = NSBezierPath(roundedRect: frontRect, xRadius: frontRadius, yRadius: frontRadius)

            // Coordinate scheda posteriore (sfalsata in basso a destra)
            let backWidth: CGFloat = 10.5
            let backHeight: CGFloat = 13.0
            let backX: CGFloat = 4.8
            let backY: CGFloat = 1.0
            let backRect = NSRect(x: backX, y: backY, width: backWidth, height: backHeight)
            let backRadius: CGFloat = 2.2
            let backPath = NSBezierPath(roundedRect: backRect, xRadius: backRadius, yRadius: backRadius)

            // Ritaglio per non sovrapporsi all'interno della scheda anteriore
            context.saveGState()
            let outerPath = CGMutablePath()
            outerPath.addRect(CGRect(x: 0, y: 0, width: 18, height: 18))
            let cgFrontPath = CGPath(roundedRect: frontRect, cornerWidth: frontRadius, cornerHeight: frontRadius, transform: nil)
            outerPath.addPath(cgFrontPath)
            context.clip(using: .evenOdd)

            backPath.lineWidth = 1.3
            backPath.stroke()
            context.restoreGState()

            // Disegno scheda anteriore
            frontPath.lineWidth = 1.4
            frontPath.stroke()

            // 3 linee orizzontali interne arrotondate (snippet copiati)
            let lineLeft = frontX + 2.2
            let lineRight = frontX + frontWidth - 2.5
            let line1Y = frontY + 8.8
            let line2Y = frontY + 6.3
            let line3Y = frontY + 3.8

            let linesPath = NSBezierPath()
            linesPath.lineCapStyle = .round
            linesPath.lineWidth = 1.1

            linesPath.move(to: NSPoint(x: lineLeft, y: line1Y))
            linesPath.line(to: NSPoint(x: lineRight - 2.0, y: line1Y))

            linesPath.move(to: NSPoint(x: lineLeft, y: line2Y))
            linesPath.line(to: NSPoint(x: lineRight, y: line2Y))

            linesPath.move(to: NSPoint(x: lineLeft, y: line3Y))
            linesPath.line(to: NSPoint(x: lineRight - 1.2, y: line3Y))

            linesPath.stroke()

            // Stella a 4 punte (Sparkle) in alto a destra con netto stacco visivo
            let starCenterX = frontX + frontWidth - 0.2
            let starCenterY = frontY + frontHeight - 0.2

            // Stacco visivo (cutout circolare trasparente)
            context.saveGState()
            context.setBlendMode(.clear)
            let cutoutRadius: CGFloat = 3.6
            let cutoutRect = NSRect(
                x: starCenterX - cutoutRadius,
                y: starCenterY - cutoutRadius,
                width: cutoutRadius * 2,
                height: cutoutRadius * 2
            )
            let cutoutPath = NSBezierPath(ovalIn: cutoutRect)
            cutoutPath.fill()
            context.restoreGState()

            // Stella a 4 punte
            let starPath = NSBezierPath()
            let rOuter: CGFloat = 3.2
            let rInner: CGFloat = 0.95

            let points: [NSPoint] = [
                NSPoint(x: starCenterX, y: starCenterY + rOuter),
                NSPoint(x: starCenterX + rInner, y: starCenterY + rInner),
                NSPoint(x: starCenterX + rOuter, y: starCenterY),
                NSPoint(x: starCenterX + rInner, y: starCenterY - rInner),
                NSPoint(x: starCenterX, y: starCenterY - rOuter),
                NSPoint(x: starCenterX - rInner, y: starCenterY - rInner),
                NSPoint(x: starCenterX - rOuter, y: starCenterY),
                NSPoint(x: starCenterX - rInner, y: starCenterY + rInner)
            ]

            starPath.move(to: points[0])
            for pt in points.dropFirst() {
                starPath.line(to: pt)
            }
            starPath.close()
            starPath.fill()

            return true
        }

        image.isTemplate = true
        return image
    }
}

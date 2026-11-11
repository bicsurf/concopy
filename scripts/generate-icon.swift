import AppKit
import CoreGraphics
import Foundation

// MARK: - Script Generatore AppIcon per ConCopy (1024x1024 px)

let outputDir = URL(fileURLWithPath: "assets", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let outputPath = outputDir.appendingPathComponent("AppIcon.png")

let size = CGSize(width: 1024, height: 1024)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

guard let context = CGContext(
    data: nil,
    width: Int(size.width),
    height: Int(size.height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("Errore: impossibile creare il contesto grafico CGContext.")
    exit(1)
}

// 1. Ombra globale sotto lo squircle macOS
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -22),
    blur: 38,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.52)
)

let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircleRadius: CGFloat = 185
let squirclePath = CGPath(
    roundedRect: squircleRect,
    cornerWidth: squircleRadius,
    cornerHeight: squircleRadius,
    transform: nil
)

context.addPath(squirclePath)
context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1.0))
context.fillPath()
context.restoreGState()

// 2. Gradiente interno dello squircle (#242426 in alto -> #141416 in basso)
context.saveGState()
context.addPath(squirclePath)
context.clip()

let bgColors = [
    CGColor(red: 0.078, green: 0.078, blue: 0.086, alpha: 1.0), // #141416 (fondo)
    CGColor(red: 0.141, green: 0.141, blue: 0.149, alpha: 1.0)  // #242426 (cima)
] as CFArray

if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
    context.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 512, y: 100),
        end: CGPoint(x: 512, y: 924),
        options: []
    )
}

// Bordo sottile di riflessione della luce superiore dello squircle
context.addPath(squirclePath)
context.setLineWidth(3)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
context.strokePath()

// 3. Scheda posteriore (Glassmorphic dark/semi-trasparente)
let backCardRect = CGRect(x: 350, y: 260, width: 370, height: 470)
let backCardPath = CGPath(roundedRect: backCardRect, cornerWidth: 50, cornerHeight: 50, transform: nil)

context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -12),
    blur: 24,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.40)
)
context.addPath(backCardPath)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
context.fillPath()
context.restoreGState()

context.addPath(backCardPath)
context.setLineWidth(3.5)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.20))
context.strokePath()

// 4. Scheda anteriore principale (Blu Elettrico #0A84FF con bagliore e linee)
let frontCardRect = CGRect(x: 270, y: 310, width: 380, height: 480)
let frontCardPath = CGPath(roundedRect: frontCardRect, cornerWidth: 54, cornerHeight: 54, transform: nil)

context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -18),
    blur: 35,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.50)
)
context.addPath(frontCardPath)
context.setFillColor(CGColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0))
context.fillPath()
context.restoreGState()

// Gradiente interno scheda anteriore (accent light top -> electric blue bottom)
context.saveGState()
context.addPath(frontCardPath)
context.clip()

let frontColors = [
    CGColor(red: 0.0, green: 0.38, blue: 0.88, alpha: 1.0),
    CGColor(red: 0.12, green: 0.58, blue: 1.0, alpha: 1.0)
] as CFArray

if let frontGradient = CGGradient(colorsSpace: colorSpace, colors: frontColors, locations: [0.0, 1.0]) {
    context.drawLinearGradient(
        frontGradient,
        start: CGPoint(x: 460, y: 310),
        end: CGPoint(x: 460, y: 790),
        options: []
    )
}

// 4 Linee orizzontali interne arrotondate (Snippet di testo copiati)
let lines: [(y: CGFloat, width: CGFloat, height: CGFloat, alpha: CGFloat)] = [
    (y: 680, width: 210, height: 22, alpha: 0.95),
    (y: 620, width: 270, height: 20, alpha: 0.78),
    (y: 565, width: 240, height: 20, alpha: 0.78),
    (y: 510, width: 170, height: 20, alpha: 0.55)
]

for item in lines {
    let lineRect = CGRect(x: 325, y: item.y, width: item.width, height: item.height)
    let linePath = CGPath(roundedRect: lineRect, cornerWidth: item.height / 2, cornerHeight: item.height / 2, transform: nil)
    context.addPath(linePath)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: item.alpha))
    context.fillPath()
}

// Bordo scheda anteriore
context.restoreGState() // esce dal clip
context.addPath(frontCardPath)
context.setLineWidth(4.0)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.42))
context.strokePath()

// 5. Stella a 4 punte ambra (#FF9F0A) in alto a destra
let starCenter = CGPoint(x: 650, y: 790)
let rOuter: CGFloat = 82
let rInner: CGFloat = 24

let starPath = CGMutablePath()
let starPoints: [CGPoint] = [
    CGPoint(x: starCenter.x, y: starCenter.y + rOuter),
    CGPoint(x: starCenter.x + rInner, y: starCenter.y + rInner),
    CGPoint(x: starCenter.x + rOuter, y: starCenter.y),
    CGPoint(x: starCenter.x + rInner, y: starCenter.y - rInner),
    CGPoint(x: starCenter.x, y: starCenter.y - rOuter),
    CGPoint(x: starCenter.x - rInner, y: starCenter.y - rInner),
    CGPoint(x: starCenter.x - rOuter, y: starCenter.y),
    CGPoint(x: starCenter.x - rInner, y: starCenter.y + rInner)
]

starPath.move(to: starPoints[0])
for pt in starPoints.dropFirst() {
    starPath.addLine(to: pt)
}
starPath.closeSubpath()

// Glow ambra attorno alla stella
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: 0),
    blur: 32,
    color: CGColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 0.85)
)
context.addPath(starPath)
context.setFillColor(CGColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 1.0))
context.fillPath()
context.restoreGState()

// Centro chiaro caldo della stella
context.saveGState()
context.addPath(starPath)
context.clip()
let starGlowColors = [
    CGColor(red: 1.0, green: 0.95, blue: 0.80, alpha: 1.0),
    CGColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1.0)
] as CFArray

if let starGradient = CGGradient(colorsSpace: colorSpace, colors: starGlowColors, locations: [0.0, 1.0]) {
    context.drawRadialGradient(
        starGradient,
        startCenter: starCenter,
        startRadius: 0,
        endCenter: starCenter,
        endRadius: rOuter,
        options: []
    )
}
context.restoreGState()

// Fine disegno: esportazione in file PNG
context.restoreGState() // chiusura clip squircle

guard let cgImage = context.makeImage() else {
    print("Errore: impossibile creare CGImage dal contesto.")
    exit(1)
}

let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    print("Errore: impossibile convertire l'immagine in formato PNG.")
    exit(1)
}

do {
    try pngData.write(to: outputPath)
    print("==> Icona master generata con successo: \(outputPath.path) (1024x1024 px)")
} catch {
    print("Errore durante il salvataggio di \(outputPath.path): \(error)")
    exit(1)
}

import AppKit
import SwiftUI

public enum ConCopyAppInfo {
    public static let fallbackVersion = "1.2.0"

    public static func loadAppIcon() -> NSImage {
        // 1. Da AppIcon.icns nel bundle principale
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: icnsURL), image.isValid {
            return image
        }

        // 2. Da AppIcon.png nel bundle principale
        if let pngURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: pngURL), image.isValid {
            return image
        }

        // 3. Fallback tramite NSImage(named:)
        if let namedIcon = NSImage(named: "AppIcon"), namedIcon.isValid {
            return namedIcon
        }

        // 4. Fallback percorso locale assets per esecuzione in ambiente dev / SPM
        let localAssetsURL = URL(fileURLWithPath: "assets/AppIcon.png")
        if let localImage = NSImage(contentsOf: localAssetsURL), localImage.isValid {
            return localImage
        }

        // 5. Fallback con disegno vettoriale dello squircle ConCopy nativo
        return generateVectorIcon()
    }

    public static var currentVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty, version != "1.0.0" {
            return version
        }
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return version
        }
        return fallbackVersion
    }

    public static var buildNumber: String {
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
           !build.isEmpty, build != "1" {
            return build
        }
        return currentVersion
    }

    public static var versionDisplayText: String {
        let v = currentVersion
        let b = buildNumber
        if v == b || b.isEmpty {
            return "Versione \(v)"
        }
        return "Versione \(v) (\(b))"
    }

    private static func generateVectorIcon() -> NSImage {
        let size = NSSize(width: 72, height: 72)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let squirclePath = CGPath(
                roundedRect: CGRect(x: 2, y: 2, width: 68, height: 68),
                cornerWidth: 15,
                cornerHeight: 15,
                transform: nil
            )

            context.addPath(squirclePath)
            context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1.0))
            context.fillPath()

            let cardPath = CGPath(
                roundedRect: CGRect(x: 18, y: 18, width: 36, height: 42),
                cornerWidth: 6,
                cornerHeight: 6,
                transform: nil
            )
            context.addPath(cardPath)
            context.setFillColor(CGColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0))
            context.fillPath()

            return true
        }
        return image
    }
}

public struct AboutView: View {
    private let currentYear: String
    private let appIcon: NSImage

    public init() {
        self.currentYear = String(Calendar.current.component(.year, from: Date()))
        self.appIcon = ConCopyAppInfo.loadAppIcon()
    }

    public var body: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 6)

            // 1. Icona App Ufficiale ConCopy
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)

            // 2. Nome App
            Text("ConCopy")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color(nsColor: NSColor(white: 0.96, alpha: 1.0)))

            // 3. Versione Dinamica
            Text(ConCopyAppInfo.versionDisplayText)
                .font(.system(size: 12))
                .foregroundColor(Color.secondary)

            // 4. Link Cliccabili separati da |
            HStack(spacing: 6) {
                linkButton(title: "GitHub", urlString: "https://github.com/bicsurf/concopy")
                Text("|")
                    .font(.system(size: 11))
                    .foregroundColor(Color.secondary.opacity(0.6))
                linkButton(title: "Releases", urlString: "https://github.com/bicsurf/concopy/releases")
                Text("|")
                    .font(.system(size: 11))
                    .foregroundColor(Color.secondary.opacity(0.6))
                linkButton(title: "Supporto", urlString: "https://github.com/bicsurf/concopy/issues")
            }

            Spacer().frame(height: 2)

            // 5. Descrizione / Crediti
            VStack(spacing: 3) {
                Text("Clipboard manager nativo a latenza zero ⚡")
                    .font(.system(size: 12))
                    .foregroundColor(Color.primary.opacity(0.9))
                Text("Sviluppato con ❤️ per macOS")
                    .font(.system(size: 12))
                    .foregroundColor(Color.secondary)
            }

            Spacer().frame(height: 4)

            // 6. Copyright
            Text("Copyright © \(currentYear) ConCopy")
                .font(.system(size: 11))
                .foregroundColor(Color.secondary.opacity(0.8))

            Spacer().frame(height: 6)
        }
        .frame(width: 280, height: 300)
        .padding(.horizontal, 16)
        .background(Color(nsColor: NSColor(white: 0.12, alpha: 1.0)))
    }

    private func linkButton(title: String, urlString: String) -> some View {
        Button(action: {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: NSColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0)))
                .underline()
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

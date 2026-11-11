import AppKit
import SwiftUI

@MainActor
public final class AboutWindowController: NSWindowController {
    public static let shared = AboutWindowController()

    public static func loadConCopyAppIcon() -> NSImage {
        ConCopyAppInfo.loadAppIcon()
    }

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 280, height: 300)
        window.maxSize = NSSize(width: 280, height: 300)
        window.setContentSize(NSSize(width: 280, height: 300))
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentView = NSHostingView(rootView: AboutView())

        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        return nil
    }

    public func showWindow(closingPanel: (() -> Void)? = nil) {
        closingPanel?()
        guard let window = self.window else { return }
        window.contentView = NSHostingView(rootView: AboutView())
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

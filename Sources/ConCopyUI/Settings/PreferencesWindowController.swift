import AppKit
import ConCopyCore
import SwiftUI

@MainActor
public final class PreferencesWindowController: NSWindowController {
    public static let shared = PreferencesWindowController()

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferenze ConCopy"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreferencesView())

        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        return nil
    }

    public func showWindow() {
        guard let window = self.window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

import AppKit
import ConCopyCore
import SwiftUI

@MainActor
public final class PreferencesWindowController: NSWindowController {
    public static let shared = PreferencesWindowController()

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Impostazioni ConCopy"
        window.minSize = NSSize(width: 500, height: 380)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreferencesView())

        super.init(window: window)
    }

    public func configure(databaseManager: DatabaseManager?, onDataChanged: (() -> Void)? = nil) {
        let view = PreferencesView(databaseManager: databaseManager, onDataChanged: onDataChanged)
        self.window?.contentView = NSHostingView(rootView: view)
    }

    public required init?(coder: NSCoder) {
        return nil
    }

    public func showWindow() {
        guard let window = self.window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

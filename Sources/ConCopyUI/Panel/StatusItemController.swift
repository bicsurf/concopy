import AppKit
import ConCopyCore

@MainActor
public final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let onToggle: () -> Void

    public init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init()
        setupStatusItem()
    }

    public convenience init(panel: FloatingPanel) {
        self.init(onToggle: { [weak panel] in
            panel?.togglePanel()
        })
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ConCopy")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            onToggle()
            return
        }

        if event.type == .rightMouseUp {
            let menu = NSMenu()

            let showItem = NSMenuItem(title: "Mostra ConCopy", action: #selector(showConCopy), keyEquivalent: "")
            showItem.target = self
            menu.addItem(showItem)

            menu.addItem(NSMenuItem.separator())

            let isPaused = AppSettingsManager.shared.isMonitoringPaused
            let pauseTitle = isPaused ? "Riprendi Registrazione Appunti" : "Pausa Registrazione Appunti"
            let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(toggleMonitoringPause), keyEquivalent: "")
            pauseItem.target = self
            menu.addItem(pauseItem)

            let prefsItem = NSMenuItem(title: "Preferenze...", action: #selector(openPreferences), keyEquivalent: ",")
            prefsItem.target = self
            menu.addItem(prefsItem)

            let updateItem = NSMenuItem(title: "Controlla aggiornamenti...", action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)

            menu.addItem(NSMenuItem.separator())

            let quitItem = NSMenuItem(title: "Esci da ConCopy", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            onToggle()
        }
    }

    @objc private func showConCopy() {
        onToggle()
    }

    @objc private func toggleMonitoringPause() {
        AppSettingsManager.shared.toggleMonitoringPaused()
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showWindow()
    }

    @objc private func checkForUpdates() {
        Task { @MainActor in
            await UpdateChecker.shared.checkForUpdatesWithUI()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

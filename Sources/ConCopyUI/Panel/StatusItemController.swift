import AppKit
import ConCopyCore

@MainActor
public final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let onToggle: () -> Void
    private let onClosePanel: (() -> Void)?
    private weak var panel: FloatingPanel?

    public init(onToggle: @escaping () -> Void, onClosePanel: (() -> Void)? = nil) {
        self.onToggle = onToggle
        self.onClosePanel = onClosePanel
        super.init()
        setupStatusItem()
    }

    public convenience init(panel: FloatingPanel) {
        self.init(onToggle: { [weak panel] in
            panel?.togglePanel()
        }, onClosePanel: { [weak panel] in
            if panel?.isVisible == true {
                panel?.orderOut(nil)
            }
        })
        self.panel = panel
    }

    public var statusButton: NSStatusBarButton? {
        statusItem?.button
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = MenuBarIcon.create()
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "ConCopy"
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

            let aboutItem = NSMenuItem(title: "Informazioni", action: #selector(openAbout), keyEquivalent: "")
            if let infoImage = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Informazioni") {
                aboutItem.image = infoImage
            }
            aboutItem.target = self
            menu.addItem(aboutItem)

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
        onClosePanel?()
        PreferencesWindowController.shared.showWindow()
    }

    @objc private func openAbout() {
        AboutWindowController.shared.showWindow(closingPanel: onClosePanel)
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

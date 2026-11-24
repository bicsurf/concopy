import AppKit
import Combine
import ConCopyCore

@MainActor
public final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let onToggle: () -> Void
    private let onClosePanel: (() -> Void)?
    private weak var panel: FloatingPanel?
    private var showIconObserver: AnyCancellable?

    public init(onToggle: @escaping () -> Void, onClosePanel: (() -> Void)? = nil) {
        self.onToggle = onToggle
        self.onClosePanel = onClosePanel
        super.init()
        let settings = AppSettingsManager.shared
        if settings.showMenuBarIcon {
            setupStatusItem()
        }
        showIconObserver = settings.$showMenuBarIcon.sink { [weak self] visible in
            self?.updateStatusItem(visible: visible)
        }
    }

    public convenience init(panel: FloatingPanel) {
        self.init(onToggle: { [weak panel] in
            panel?.togglePanel()
        }, onClosePanel: { [weak panel] in
            if panel?.isVisible == true {
                panel?.hidePanel(restoreFocus: false)
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

    private func updateStatusItem(visible: Bool) {
        if visible {
            if statusItem == nil {
                setupStatusItem()
            }
        } else {
            statusItem?.menu = nil
            statusItem = nil
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            onToggle()
            return
        }

        if event.type == .rightMouseUp {
            let menu = NSMenu()

            let showItem = NSMenuItem(title: "Show ConCopy", action: #selector(showConCopy), keyEquivalent: "")
            showItem.target = self
            menu.addItem(showItem)

            let hideIconItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideMenuBarIcon), keyEquivalent: "")
            hideIconItem.target = self
            menu.addItem(hideIconItem)

            menu.addItem(NSMenuItem.separator())

            let isPaused = AppSettingsManager.shared.isMonitoringPaused
            let pauseTitle = isPaused ? "Resume Clipboard Recording" : "Pause Clipboard Recording"
            let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(toggleMonitoringPause), keyEquivalent: "")
            pauseItem.target = self
            menu.addItem(pauseItem)

            let prefsItem = NSMenuItem(title: "Settings...", action: #selector(openPreferences), keyEquivalent: ",")
            prefsItem.target = self
            menu.addItem(prefsItem)

            let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)

            let aboutItem = NSMenuItem(title: "About", action: #selector(openAbout), keyEquivalent: "")
            if let infoImage = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About") {
                aboutItem.image = infoImage
            }
            aboutItem.target = self
            menu.addItem(aboutItem)

            menu.addItem(NSMenuItem.separator())

            let quitItem = NSMenuItem(title: "Quit ConCopy", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            if let button = statusItem?.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
            }
        } else {
            onToggle()
        }
    }

    @objc private func showConCopy() {
        if let panel = panel {
            panel.showPanel()
        } else {
            onToggle()
        }
    }

    @objc private func hideMenuBarIcon() {
        AppSettingsManager.shared.showMenuBarIcon = false
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

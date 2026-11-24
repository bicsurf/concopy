import AppKit
import ConCopyCore
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

public enum PreferencesTab: String, CaseIterable, Identifiable {
    case general = "General"
    case history = "History"
    case shortcuts = "Shortcuts"
    case blacklist = "Privacy"

    public var id: String { rawValue }
}

@MainActor
public struct PreferencesView: View {
    @ObservedObject private var settingsManager: AppSettingsManager
    @ObservedObject private var shortcutsManager = GlobalShortcutsManager.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared
    public var databaseManager: DatabaseManager?
    public var onDataChanged: (() -> Void)?

    @State private var selectedTab: PreferencesTab = .general
    @State private var selectedBundleId: String? = nil
    @State private var isShowingManualAddSheet: Bool = false
    @State private var manualBundleIdText: String = ""
    @State private var isShowingClearConfirm: Bool = false
    @State private var statusAlertMessage: String? = nil
    @State private var isImporting: Bool = false
    @State private var importProgressDescription: String = ""
    @State private var detectedMaccyURL: URL? = nil
    @State private var isShowingMaccyAutoDetectAlert: Bool = false

    public init(
        settingsManager: AppSettingsManager? = nil,
        databaseManager: DatabaseManager? = nil,
        onDataChanged: (() -> Void)? = nil
    ) {
        self.settingsManager = settingsManager ?? .shared
        self.databaseManager = databaseManager
        self.onDataChanged = onDataChanged
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $selectedTab) {
                ForEach(PreferencesTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    generalTabView
                case .history:
                    historyTabView
                case .shortcuts:
                    shortcutsTabView
                case .blacklist:
                    blacklistTabView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(ConCopyTheme.Accents.primary)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 450, idealHeight: 520)
        .sheet(isPresented: $isShowingManualAddSheet) {
            manualAddSheet
        }
        .alert("Clear History?", isPresented: $isShowingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearHistoryAction()
            }
        } message: {
            Text("All clips not marked as favorites will be permanently deleted from disk.")
        }
        .alert(
            "Operation Completed",
            isPresented: Binding(
                get: { statusAlertMessage != nil },
                set: { if !$0 { statusAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { statusAlertMessage = nil }
        } message: {
            Text(statusAlertMessage ?? "")
        }
        .alert("Maccy Database Detected", isPresented: $isShowingMaccyAutoDetectAlert) {
            Button("Import Directly") {
                if let url = detectedMaccyURL {
                    executeImport(importer: MaccyImporter(sourceURL: url))
                }
            }
            Button("Choose Another File...") {
                openMaccyFilePicker()
            }
            Button("Cancel", role: .cancel) {
                detectedMaccyURL = nil
            }
        } message: {
            Text(
                "A Maccy database was found at:\n\(detectedMaccyURL?.path ?? "")\n\nDo you want to import it directly?")
        }
    }

    // MARK: - General Tab
    private var generalTabView: some View {
        Form {
            Section(header: Text("Clipboard Monitoring")) {
                Toggle(
                    isOn: Binding(
                        get: { !settingsManager.isMonitoringPaused },
                        set: { settingsManager.isMonitoringPaused = !$0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Record clipboard history")
                        Text("Save copied items so you can use them again later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Record clipboard history")
                .accessibilityHint("Save copied items so you can use them again later.")
                Toggle(isOn: $settingsManager.autoCaptureScreenshots) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Capture macOS screenshots")
                        Text("Add new screenshots to your clipboard history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Capture macOS screenshots")
                .accessibilityHint("Add new screenshots to your clipboard history.")
            }

            Section(header: Text("General")) {
                Toggle("Launch automatically at login", isOn: $settingsManager.launchAtLogin)
                Toggle("Show menu bar icon", isOn: $settingsManager.showMenuBarIcon)
                Text("When hidden, reopen ConCopy with the panel shortcut, then re-enable this in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Picker("When clicking a clip", selection: $settingsManager.isDirectPasteEnabled) {
                        Text("Copy to clipboard").tag(false)
                        Text("Paste into active app").tag(true)
                    }
                    Text(
                        settingsManager.isDirectPasteEnabled
                            ? "A click pastes the clip into the app you were using and closes the panel."
                            : "A click copies the clip and closes the panel. Paste with ⌘V when you’re ready."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Panel opening position", selection: $settingsManager.panelPositionMode) {
                        ForEach(PanelPositionMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(settingsManager.panelPositionMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("Updates")) {
                HStack {
                    Text("Installed version:")
                    Spacer()
                    Text("v\(updateChecker.currentVersion)")
                        .foregroundColor(.secondary)
                }

                Toggle(isOn: $settingsManager.isAutoCheckUpdatesEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Check for updates automatically")
                        Text("Check for new versions at launch and every day.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                .accessibilityLabel("Check for updates automatically")
                .accessibilityHint("Check for new versions at launch and every day.")

                HStack {
                    Button(action: {
                        Task {
                            await updateChecker.checkForUpdatesWithUI()
                        }
                    }) {
                        HStack(spacing: 6) {
                            if updateChecker.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(updateChecker.isChecking ? "Checking..." : "Check Now")
                        }
                    }
                    .disabled(updateChecker.isChecking)

                    if let status = updateChecker.statusMessage {
                        Spacer()
                        Text(status)
                            .font(.caption)
                            .foregroundColor(
                                updateChecker.availableUpdate != nil ? ConCopyTheme.Accents.primary : .secondary)
                    }
                }
            }

            Section(header: Text("iCloud Drive Sync")) {
                Toggle("iCloud Drive Sync", isOn: $settingsManager.iCloudSyncEnabled)
                    .disabled(!CloudKitSyncCoordinator.isCloudDriveAvailable)

                if CloudKitSyncCoordinator.isCloudDriveAvailable {
                    Text("Automatic and private clip synchronization between your Macs via your iCloud Drive folder.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("iCloud Drive is unavailable or disabled on this Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - History Tab
    private var historyTabView: some View {
        Form {
            Section(header: Text("History & Cleanup")) {
                Toggle("Automatic cleanup", isOn: $settingsManager.autoCleanupEnabled)

                if settingsManager.autoCleanupEnabled {
                    Picker("Delete clips older than:", selection: $settingsManager.retentionDays) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }

                    Picker("Maximum history size:", selection: $settingsManager.maxHistoryCount) {
                        Text("200 items").tag(200)
                        Text("500 items").tag(500)
                        Text("1000 items").tag(1000)
                        Text("5000 items").tag(5000)
                    }
                }

                Text("Favorites and clips in your lists are kept during automatic cleanup.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(
                    role: .destructive,
                    action: {
                        isShowingClearConfirm = true
                    }
                ) {
                    Label("Clear History", systemImage: "trash")
                        .foregroundColor(.red)
                }
            }

            Section(header: Text("Backup & Restore")) {
                HStack(spacing: 12) {
                    Button(action: exportBackupAction) {
                        Label("Export Archive...", systemImage: "square.and.arrow.up")
                    }
                    Button(action: importBackupAction) {
                        Label("Import Archive...", systemImage: "square.and.arrow.down")
                    }
                }
                Text("Save or restore your clips, images and lists in a single backup archive.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Import from Other Apps")) {
                if isImporting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(importProgressDescription.isEmpty ? "Importing..." : importProgressDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 12) {
                        Button(action: importFromMaccyAction) {
                            Label("Import from Maccy...", systemImage: "arrow.down.doc")
                        }
                        Button(action: importFromCopyEmAction) {
                            Label("Import from Copy 'Em...", systemImage: "arrow.down.doc")
                        }
                    }
                    Text("Bring over history, lists and favorites without creating duplicates.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts Tab
    private var shortcutsTabView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keyboard Shortcuts Customization")
                            .font(.headline)
                        Text(
                            "Configure or clear global and panel shortcuts. Click on a field to record a combination, or use the clear button to disable it."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                    // Toggle numeric modifiers swap
                    Toggle(
                        isOn: Binding(
                            get: { shortcutsManager.swapNumericModifiers },
                            set: { shortcutsManager.setSwapNumericModifiers($0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Swap numeric modifiers (⌘ ⇋ ⌘⌥)")
                                .font(.system(size: 13, weight: .semibold))
                            Text(
                                shortcutsManager.swapNumericModifiers
                                    ? "Active: ⌘⌥ to select lists and ⌘ for quick paste"
                                    : "Default: ⌘ to select lists and ⌘⌥ for quick paste"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ConCopyTheme.Surfaces.pillBackground.opacity(0.6))
                    )
                    .padding(.horizontal, 16)

                    Divider().opacity(0.4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("General Commands")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(ConCopyTheme.Accents.primary)
                            .padding(.leading, 2)

                        VStack(spacing: 6) {
                            ForEach(ConCopyShortcutKey.allCases) { key in
                                shortcutRow(for: key)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Button(role: .destructive) {
                    shortcutsManager.resetAll()
                } label: {
                    Label("Reset All to Defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ConCopyTheme.Surfaces.pillBackground.opacity(0.3))
        }
    }

    @ViewBuilder
    private func shortcutRow(for key: ConCopyShortcutKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: key.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ConCopyTheme.Accents.primary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ConCopyTheme.Surfaces.pillBackground)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(key.displayName)
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 6) {
                    Text(key.scope.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(key.scope == .global ? ConCopyTheme.Accents.snippet : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(
                                    key.scope == .global
                                        ? ConCopyTheme.Accents.snippet.opacity(0.15)
                                        : ConCopyTheme.Surfaces.pillBackground)
                        )

                    if let def = key.defaultShortcut {
                        Text("Default: \(def.description)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            KeyboardShortcuts.Recorder(for: key.shortcutName) { _ in
                if key.scope == .inPanel {
                    KeyboardShortcuts.disable(key.shortcutName)
                }
                shortcutsManager.notifyShortcutChanged()
            }
            .id("\(key.rawValue)-\(shortcutsManager.changeVersion)")

            HStack(spacing: 4) {
                if key.currentShortcut != nil {
                    Button {
                        shortcutsManager.removeShortcut(for: key)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove shortcut")
                }

                Button {
                    shortcutsManager.resetShortcut(for: key)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ConCopyTheme.Surfaces.pillBackground.opacity(0.45))
        )
    }

    // MARK: - Blacklist Tab
    private var blacklistTabView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep sensitive content out of your history. Anything copied from these apps is ignored.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            List(selection: $selectedBundleId) {
                if settingsManager.excludedAppBundleIds.isEmpty {
                    Text("No excluded applications")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ForEach(settingsManager.excludedAppBundleIds, id: \.self) { bundleId in
                        let info = resolveAppInfo(for: bundleId)
                        HStack(spacing: 10) {
                            if let icon = info.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(bundleId)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button(action: {
                                settingsManager.removeExcludedApp(bundleId: bundleId)
                                if selectedBundleId == bundleId {
                                    selectedBundleId = nil
                                }
                            }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from excluded list")
                        }
                        .tag(bundleId)
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 20)

            HStack(spacing: 8) {
                Menu {
                    Button("Choose Application (.app)...") {
                        chooseAppFile()
                    }
                    if let frontmost = NSWorkspace.shared.frontmostApplication,
                        let bundleId = frontmost.bundleIdentifier
                    {
                        Button("Add active app (\(frontmost.localizedName ?? bundleId))") {
                            settingsManager.addExcludedApp(bundleId: bundleId)
                        }
                    }
                    Button("Enter Bundle ID manually...") {
                        manualBundleIdText = ""
                        isShowingManualAddSheet = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24, height: 20)

                Button(action: {
                    if let selected = selectedBundleId {
                        settingsManager.removeExcludedApp(bundleId: selected)
                        selectedBundleId = nil
                    }
                }) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(selectedBundleId == nil)
                .frame(width: 24, height: 20)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Manual Add Sheet
    private var manualAddSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Bundle ID to Exclude")
                .font(.headline)

            Text("Enter the unique application bundle identifier (e.g. com.apple.keychainaccess)")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("com.example.app", text: $manualBundleIdText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingManualAddSheet = false
                }
                Button("Add") {
                    let cleaned = manualBundleIdText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        settingsManager.addExcludedApp(bundleId: cleaned)
                    }
                    isShowingManualAddSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(manualBundleIdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Helper Methods
    private func chooseAppFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.application]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        openPanel.prompt = "Select"

        if openPanel.runModal() == .OK, let url = openPanel.url {
            if let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier {
                settingsManager.addExcludedApp(bundleId: bundleId)
            }
        }
    }

    private func resolveAppInfo(for bundleId: String) -> (name: String, icon: NSImage?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let name = FileManager.default.displayName(atPath: url.path)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return (name, icon)
        }
        return (bundleId, nil)
    }

    private func clearHistoryAction() {
        guard let db = databaseManager else { return }
        Task {
            do {
                let count = try await Task.detached(priority: .utility) {
                    try db.clearAllHistory(preserveFavorites: true)
                }.value
                onDataChanged?()
                statusAlertMessage = "Cleared \(count) clips from history"
            } catch { statusAlertMessage = "Error clearing history: \(error.localizedDescription)" }
        }
    }

    private func exportBackupAction() {
        guard let db = databaseManager else {
            statusAlertMessage = "Database unavailable"
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "ConCopy_Backup_\(ISO8601DateFormatter().string(from: Date())).json"
        savePanel.prompt = "Export"

        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            Task.detached(priority: .utility) {
                do {
                    try await ArchiveManager().exportArchive(to: targetURL, databaseManager: db)
                    await MainActor.run {
                        self.statusAlertMessage = "Archive exported successfully to:\n\(targetURL.lastPathComponent)"
                    }
                } catch {
                    await MainActor.run {
                        self.statusAlertMessage = "Error exporting archive:\n\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func importBackupAction() {
        guard let db = databaseManager else {
            statusAlertMessage = "Database unavailable"
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.prompt = "Import"

        if openPanel.runModal() == .OK, let sourceURL = openPanel.url {
            Task.detached(priority: .utility) {
                do {
                    try await ArchiveManager().importArchive(from: sourceURL, databaseManager: db)
                    await MainActor.run {
                        self.onDataChanged?()
                        self.statusAlertMessage = "Archive imported successfully from:\n\(sourceURL.lastPathComponent)"
                    }
                } catch {
                    await MainActor.run {
                        self.statusAlertMessage = "Error importing archive:\n\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func importFromMaccyAction() {
        if let autoDetected = MaccyImporter.detectStandardDatabaseURL() {
            detectedMaccyURL = autoDetected
            isShowingMaccyAutoDetectAlert = true
            return
        }
        openMaccyFilePicker()
    }

    private func openMaccyFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [
            UTType(filenameExtension: "sqlite") ?? .data,
            UTType(filenameExtension: "db") ?? .data,
        ]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = true
        openPanel.prompt = "Import"
        if let defaultDir = MaccyImporter.standardLocations.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            openPanel.directoryURL = defaultDir
        }

        if openPanel.runModal() == .OK, let selectedURL = openPanel.url {
            executeImport(importer: MaccyImporter(sourceURL: selectedURL), securityScopedURL: selectedURL)
        }
    }

    private func importFromCopyEmAction() {
        let openPanel = NSOpenPanel()
        var types: [UTType] = [
            UTType(filenameExtension: "storedata") ?? .data,
            UTType(filenameExtension: "sqlite") ?? .data,
            UTType(filenameExtension: "db") ?? .data,
            .package,
            .folder,
        ]
        if let cepType = UTType(filenameExtension: "cep") {
            types.insert(cepType, at: 0)
        }
        openPanel.allowedContentTypes = types
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = true
        openPanel.treatsFilePackagesAsDirectories = true
        openPanel.prompt = "Import"
        if let defaultDir = CopyEmImporter.standardLocations.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            openPanel.directoryURL = defaultDir
        }

        if openPanel.runModal() == .OK, let selectedURL = openPanel.url {
            executeImport(importer: CopyEmImporter(sourceURL: selectedURL), securityScopedURL: selectedURL)
        }
    }

    private func executeImport(importer: any ExternalClipboardImporter, securityScopedURL: URL? = nil) {
        guard let db = databaseManager else {
            statusAlertMessage = "Database unavailable"
            return
        }

        isImporting = true
        importProgressDescription = "Starting import from \(importer.displayName)..."

        Task.detached(priority: .utility) {
            let hasScopedAccess = securityScopedURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if hasScopedAccess {
                    securityScopedURL?.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let result = try importer.importClips(into: db) { progress in
                    Task { @MainActor in
                        if let total = progress.total, total > 0 {
                            self.importProgressDescription =
                                "\(progress.processed)/\(total) processed (\(progress.imported) imported, \(progress.merged) merged)"
                        } else {
                            self.importProgressDescription =
                                "\(progress.processed) processed (\(progress.imported) imported, \(progress.merged) merged)"
                        }
                    }
                }

                await MainActor.run {
                    self.isImporting = false
                    self.importProgressDescription = ""
                    self.onDataChanged?()
                    self.statusAlertMessage = """
                        Import from \(importer.displayName) completed!
                        • \(result.importedCount) new clips imported
                        • \(result.mergedDuplicatesCount) duplicate clips merged
                        • \(result.createdListsCount) new lists created
                        • \(result.errorsCount) errors
                        """
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.importProgressDescription = ""
                    self.statusAlertMessage =
                        "Error importing from \(importer.displayName): \(error.localizedDescription)"
                }
            }
        }
    }
}

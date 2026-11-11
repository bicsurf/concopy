import AppKit
import ConCopyCore
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

public enum PreferencesTab: String, CaseIterable, Identifiable {
    case general = "Generale"
    case blacklist = "App Escluse"

    public var id: String { rawValue }
}

@MainActor
public struct PreferencesView: View {
    @ObservedObject private var settingsManager: AppSettingsManager
    @ObservedObject private var updateChecker = UpdateChecker.shared
    public var databaseManager: DatabaseManager?
    public var onDataChanged: (() -> Void)?

    @State private var selectedTab: PreferencesTab = .general
    @State private var selectedBundleId: String? = nil
    @State private var isShowingManualAddSheet: Bool = false
    @State private var manualBundleIdText: String = ""
    @State private var isShowingClearConfirm: Bool = false
    @State private var statusAlertMessage: String? = nil

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
            Picker("", selection: $selectedTab) {
                ForEach(PreferencesTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    generalTabView
                case .blacklist:
                    blacklistTabView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 380, idealHeight: 460)
        .sheet(isPresented: $isShowingManualAddSheet) {
            manualAddSheet
        }
        .alert("Svuotare la Cronologia?", isPresented: $isShowingClearConfirm) {
            Button("Annulla", role: .cancel) {}
            Button("Svuota", role: .destructive) {
                clearHistoryAction()
            }
        } message: {
            Text("Tutte le clip non contrassegnate come preferite verranno eliminate definitivamente dal disco")
        }
        .alert("Operazione Completata", isPresented: Binding(
            get: { statusAlertMessage != nil },
            set: { if !$0 { statusAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { statusAlertMessage = nil }
        } message: {
            Text(statusAlertMessage ?? "")
        }
    }

    // MARK: - General Tab
    private var generalTabView: some View {
        Form {
            Section(header: Text("Scorciatoia Globale")) {
                HStack {
                    Text("Apri/Chiudi ConCopy:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleConCopyPanel)
                }
                Text("Scorciatoia globale di sistema per mostrare o nascondere la finestra flottante di ConCopy (predefinito: ⇧⌘V)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Monitoraggio Appunti")) {
                Toggle("Pausa registrazione appunti", isOn: $settingsManager.isMonitoringPaused)
                Text("Quando attiva, ConCopy non registrerà nuovi elementi copiati negli appunti")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Cattura screenshot macOS", isOn: $settingsManager.autoCaptureScreenshots)
                Text("Salva automaticamente le nuove schermate acquisite nella cartella screenshot")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Generale")) {
                Toggle("Avvia automaticamente all'accessione", isOn: $settingsManager.launchAtLogin)
                Toggle("Incolla direttamente nella selezione", isOn: $settingsManager.isDirectPasteEnabled)
                Text("Se attivo, selezionare una clip la incolla immediatamente nell'app attiva. Se disattivato, la copia solo negli appunti (usa Cmd+V per incollare)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Section(header: Text("Incollaggio")) {

            Section(header: Text("Cronologia & Pulizia")) {
                Toggle("Pulizia automatica", isOn: $settingsManager.autoCleanupEnabled)

                if settingsManager.autoCleanupEnabled {
                    Picker("Elimina clip più vecchie di:", selection: $settingsManager.retentionDays) {
                        Text("7 giorni").tag(7)
                        Text("14 giorni").tag(14)
                        Text("30 giorni").tag(30)
                        Text("90 giorni").tag(90)
                    }

                    Picker("Capacità massima cronologia:", selection: $settingsManager.maxHistoryCount) {
                        Text("200 elementi").tag(200)
                        Text("500 elementi").tag(500)
                        Text("1000 elementi").tag(1000)
                        Text("5000 elementi").tag(5000)
                    }
                }

                Text("Nota: gli elementi preferiti (★) non vengono mai eliminati automaticamente")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(role: .destructive, action: {
                    isShowingClearConfirm = true
                }) {
                    Label("Svuota Cronologia", systemImage: "trash")
                        .foregroundColor(.red)
                }
            }

            Section(header: Text("Backup & Ripristino")) {
                HStack(spacing: 12) {
                    Button(action: exportBackupAction) {
                        Label("Esporta Archivio...", systemImage: "square.and.arrow.up")
                    }
                    Button(action: importBackupAction) {
                        Label("Importa Archivio...", systemImage: "square.and.arrow.down")
                    }
                }
                Text("Esporta o ripristina tutte le clip (inclusi blob e immagini) e le liste in formato JSON")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Aggiornamenti")) {
                HStack {
                    Text("Versione installata:")
                    Spacer()
                    Text("v\(updateChecker.currentVersion)")
                        .foregroundColor(.secondary)
                }

                Toggle("Controlla aggiornamenti automaticamente", isOn: $settingsManager.isAutoCheckUpdatesEnabled)
                Text("Verifica periodicamente su GitHub la presenza di nuove versioni di ConCopy")
                    .font(.caption)
                    .foregroundColor(.secondary)

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
                            Text(updateChecker.isChecking ? "Verifica in corso..." : "Verifica ora")
                        }
                    }
                    .disabled(updateChecker.isChecking)

                    if let status = updateChecker.statusMessage {
                        Spacer()
                        Text(status)
                            .font(.caption)
                            .foregroundColor(updateChecker.availableUpdate != nil ? ConCopyTheme.Accents.primary : .secondary)
                    }
                }
            }

            Section(header: Text("Sincronizzazione iCloud Drive")) {
                Toggle("Sincronizzazione iCloud Drive", isOn: $settingsManager.iCloudSyncEnabled)
                    .disabled(!CloudKitSyncCoordinator.isCloudDriveAvailable)

                if CloudKitSyncCoordinator.isCloudDriveAvailable {
                    Text("Replicazione automatica e privata delle clip tra i tuoi Mac tramite la cartella iCloud Drive.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("iCloud Drive non disponibile o disabilitato su questo Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Blacklist Tab
    private var blacklistTabView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Le applicazioni in questa lista non verranno monitorate. I contenuti copiati da esse verranno ignorati")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            List(selection: $selectedBundleId) {
                if settingsManager.excludedAppBundleIds.isEmpty {
                    Text("Nessuna applicazione esclusa")
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
                            .help("Rimuovi dalla blacklist")
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
                    Button("Scegli Applicazione (.app)...") {
                        chooseAppFile()
                    }
                    if let frontmost = NSWorkspace.shared.frontmostApplication,
                        let bundleId = frontmost.bundleIdentifier {
                        Button("Aggiungi app attiva (\(frontmost.localizedName ?? bundleId))") {
                            settingsManager.addExcludedApp(bundleId: bundleId)
                        }
                    }
                    Button("Inserisci Bundle ID manualmente...") {
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
            Text("Aggiungi Bundle ID da escludere")
                .font(.headline)

            Text("Inserisci l'identificatore bundle univoco dell'applicazione (es: com.apple.keychainaccess)")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("com.example.app", text: $manualBundleIdText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Annulla") {
                    isShowingManualAddSheet = false
                }
                Button("Aggiungi") {
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
        openPanel.prompt = "Seleziona"

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
        do {
            let count = try db.clearAllHistory(preserveFavorites: true)
            onDataChanged?()
            statusAlertMessage = "Eliminate \(count) clip dalla cronologia"
        } catch {
            statusAlertMessage = "Errore durante lo svuotamento: \(error.localizedDescription)"
        }
    }

    private func exportBackupAction() {
        guard let db = databaseManager else {
            statusAlertMessage = "Database non disponibile"
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "ConCopy_Backup_\(ISO8601DateFormatter().string(from: Date())).json"
        savePanel.prompt = "Esporta"

        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            Task.detached(priority: .utility) {
                do {
                    try await ArchiveManager().exportArchive(to: targetURL, databaseManager: db)
                    await MainActor.run {
                        self.statusAlertMessage = "Archivio esportato con successo in:\n\(targetURL.lastPathComponent)"
                    }
                } catch {
                    await MainActor.run {
                        self.statusAlertMessage = "Errore durante l'esportazione:\n\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func importBackupAction() {
        guard let db = databaseManager else {
            statusAlertMessage = "Database non disponibile"
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.prompt = "Importa"

        if openPanel.runModal() == .OK, let sourceURL = openPanel.url {
            Task.detached(priority: .utility) {
                do {
                    try await ArchiveManager().importArchive(from: sourceURL, databaseManager: db)
                    await MainActor.run {
                        self.onDataChanged?()
                        self.statusAlertMessage = "Archivio importato con successo da:\n\(sourceURL.lastPathComponent)"
                    }
                } catch {
                    await MainActor.run {
                        self.statusAlertMessage = "Errore durante l'importazione:\n\(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

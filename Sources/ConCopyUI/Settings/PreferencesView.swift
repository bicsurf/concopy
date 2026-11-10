import AppKit
import ConCopyCore
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
    @State private var selectedTab: PreferencesTab = .general
    @State private var selectedBundleId: String? = nil
    @State private var isShowingManualAddSheet: Bool = false
    @State private var manualBundleIdText: String = ""

    public init(settingsManager: AppSettingsManager? = nil) {
        self.settingsManager = settingsManager ?? .shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(PreferencesTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

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
        .frame(width: 500, height: 460)
        .sheet(isPresented: $isShowingManualAddSheet) {
            manualAddSheet
        }
    }

    // MARK: - General Tab
    private var generalTabView: some View {
        ScrollView {
            Form {
                Section {
                    Toggle("Pausa registrazione appunti", isOn: $settingsManager.isMonitoringPaused)
                        .font(.body)
                    Text("Quando attiva, ConCopy non registrerà nuovi elementi copiati negli appunti.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle("Cattura automatica screenshot macOS", isOn: $settingsManager.autoCaptureScreenshots)
                        .font(.body)
                    Text("Salva automaticamente le nuove schermate acquisite nella cartella screenshot.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle("Avvia automaticamente all'accesso", isOn: $settingsManager.launchAtLogin)
                        .font(.body)
                    Text("Avvia l'applicazione all'avvio della sessione macOS.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle("Pulizia automatica cronologia", isOn: $settingsManager.autoCleanupEnabled)
                        .font(.body)

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

                    Text("Nota: gli elementi preferiti (★) non vengono mai eliminati automaticamente.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle("Sincronizzazione iCloud (CloudKit)", isOn: $settingsManager.iCloudSyncEnabled)
                        .font(.body)
                    Text("Replicazione crittografata e privata delle clip testuali e delle liste tra i tuoi dispositivi Apple.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scorciatoia Globale")
                            .font(.headline)
                        Text("Premi ⌘⇧V (Cmd + Shift + V) per mostrare o nascondere ConCopy.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Blacklist Tab
    private var blacklistTabView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Le applicazioni in questa lista non verranno monitorate. I contenuti copiati da esse non saranno salvati.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            List(selection: $selectedBundleId) {
                ForEach(settingsManager.excludedAppBundleIds, id: \.self) { bundleId in
                    let info = resolveAppInfo(for: bundleId)
                    HStack(spacing: 10) {
                        if let icon = info.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "app.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.name)
                                .font(.system(size: 12, weight: .semibold))
                            Text(bundleId)
                                .font(.system(size: 10, design: .monospaced))
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
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Rimuovi dalla blacklist")
                    }
                    .tag(bundleId)
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .border(Color.secondary.opacity(0.15))
            .padding(.horizontal, 16)

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
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Manual Add Sheet
    private var manualAddSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aggiungi Bundle ID da escludere")
                .font(.headline)

            Text("Inserisci l'identificatore bundle univoco dell'applicazione (es: com.apple.keychainaccess).")
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
}

import AppKit
import ConCopyCore
import Foundation

@MainActor
public final class UpdateChecker: ObservableObject {
    public static let shared = UpdateChecker()

    public enum CheckResult: Sendable {
        case updateAvailable(AvailableUpdate)
        case upToDate
        case failed(String)
    }

    @Published public var availableUpdate: AvailableUpdate? = nil
    @Published public var isChecking: Bool = false
    @Published public var statusMessage: String? = nil

    public let appSettings: AppSettingsManager
    public let currentVersionProvider: () -> String
    private let session: URLSession
    private let endpoint: URL

    public var currentVersion: String {
        currentVersionProvider()
    }

    public init(
        appSettings: AppSettingsManager? = nil,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.github.com/repos/bicsurf/concopy/releases/latest")!,
        currentVersionProvider: @escaping () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        }
    ) {
        self.appSettings = appSettings ?? AppSettingsManager.shared
        self.session = session
        self.endpoint = endpoint
        self.currentVersionProvider = currentVersionProvider
    }

    public func checkAutomaticallyIfNeeded() async {
        guard appSettings.isAutoCheckUpdatesEnabled else { return }

        if let lastCheck = appSettings.lastUpdateCheckDate,
           Date().timeIntervalSince(lastCheck) < 12 * 3600 {
            return
        }

        let result = await checkForUpdates(isUserInitiated: false)
        if case .updateAvailable(let update) = result {
            if update.version == appSettings.skippedUpdateVersion {
                self.availableUpdate = nil
            }
        }
    }

    @discardableResult
    public func checkForUpdates(isUserInitiated: Bool = false) async -> CheckResult {
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("ConCopy-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                let msg = "Risposta non valida dal server."
                self.statusMessage = msg
                return .failed(msg)
            }

            if httpResponse.statusCode == 404 {
                // Nessuna release ancora pubblicata sul repo
                self.availableUpdate = nil
                self.statusMessage = "Nessun aggiornamento pubblicato."
                return .upToDate
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let msg = "Errore HTTP \(httpResponse.statusCode)"
                self.statusMessage = msg
                return .failed(msg)
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            appSettings.lastUpdateCheckDate = Date()

            var cleanTag = release.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanTag.lowercased().hasPrefix("v") {
                cleanTag.removeFirst()
            }

            let remoteVer = SemanticVersion(cleanTag)
            let localVer = SemanticVersion(currentVersion)

            if remoteVer > localVer {
                let dmgAsset = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
                let dmgURL = dmgAsset.flatMap { URL(string: $0.browserDownloadUrl) }
                let pageURL = URL(string: release.htmlUrl) ?? endpoint

                let update = AvailableUpdate(
                    version: cleanTag,
                    title: release.name ?? "ConCopy v\(cleanTag)",
                    releaseNotes: release.body ?? "",
                    releasePageURL: pageURL,
                    dmgDownloadURL: dmgURL
                )

                if !isUserInitiated && cleanTag == appSettings.skippedUpdateVersion {
                    self.availableUpdate = nil
                    self.statusMessage = "Versione v\(cleanTag) ignorata"
                    return .upToDate
                }

                self.availableUpdate = update
                self.statusMessage = "Disponibile v\(cleanTag)"
                return .updateAvailable(update)
            } else {
                self.availableUpdate = nil
                self.statusMessage = "Sei all'ultima versione (v\(currentVersion))"
                return .upToDate
            }
        } catch {
            let msg = error.localizedDescription
            self.statusMessage = "Errore: \(msg)"
            return .failed(msg)
        }
    }

    public func checkForUpdatesWithUI() async {
        let result = await checkForUpdates(isUserInitiated: true)

        switch result {
        case .updateAvailable(let update):
            let alert = NSAlert()
            alert.messageText = "Nuova versione disponibile: v\(update.version)"
            alert.informativeText = "\(update.title)\n\n\(update.releaseNotes.isEmpty ? "Nessuna nota di rilascio fornita." : update.releaseNotes)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: update.dmgDownloadURL != nil ? "Scarica DMG" : "Apri Release")
            alert.addButton(withTitle: "Ignora questa versione")
            alert.addButton(withTitle: "Più tardi")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = update.dmgDownloadURL ?? URL(string: update.releasePageURL.absoluteString) {
                    NSWorkspace.shared.open(url)
                }
            } else if response == .alertSecondButtonReturn {
                skipUpdate(version: update.version)
            }

        case .upToDate:
            let alert = NSAlert()
            alert.messageText = "ConCopy è aggiornato"
            alert.informativeText = "Stai già utilizzando l'ultima versione disponibile (v\(currentVersion))."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .failed(let reason):
            let alert = NSAlert()
            alert.messageText = "Controllo aggiornamenti fallito"
            alert.informativeText = "Impossibile verificare la presenza di aggiornamenti.\n\n\(reason)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    public func skipUpdate(version: String) {
        appSettings.skippedUpdateVersion = version
        self.availableUpdate = nil
    }

    public func dismissUpdate() {
        self.availableUpdate = nil
    }
}

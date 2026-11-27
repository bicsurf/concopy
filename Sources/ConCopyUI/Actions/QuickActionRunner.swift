import AppKit
import Foundation
import ConCopyCore

public enum QuickActionType: String, Codable, CaseIterable, Sendable {
    case terminal = "terminal"
    case openInBrowser = "openInBrowser"
    case openInTextEdit = "openInTextEdit"
    case runShellScript = "runShellScript"
    case shareSheet = "shareSheet"

    public var title: String {
        switch self {
        case .terminal: return "Send to Terminal"
        case .openInBrowser: return "Open in Default Browser"
        case .openInTextEdit: return "Open in TextEdit"
        case .runShellScript: return "Run as Shell Command"
        case .shareSheet: return "Share..."
        }
    }

    public var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .openInBrowser: return "safari"
        case .openInTextEdit: return "text.badge.plus"
        case .runShellScript: return "play.circle"
        case .shareSheet: return "square.and.arrow.up"
        }
    }
}

public struct QuickActionRunner: Sendable {
    public static func canExecute(_ action: QuickActionType, for clip: ClipRecord) -> Bool {
        guard let text = clip.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return false
        }
        switch action {
        case .terminal, .openInTextEdit, .runShellScript, .shareSheet:
            return true
        case .openInBrowser:
            if clip.primaryType == .url { return true }
            return text.hasPrefix("http://") || text.hasPrefix("https://")
        }
    }

    @MainActor
    public static func execute(_ action: QuickActionType, text: String, skipConfirmation: Bool = false, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            completion("Empty text")
            return
        }

        switch action {
        case .terminal:
            let appleScript = """
            tell application "Terminal"
                activate
                do script "\(escapeAppleScript(cleaned))"
            end tell
            """
            runAppleScript(appleScript, completion: completion)

        case .openInBrowser:
            if let url = URL(string: cleaned), url.scheme != nil {
                NSWorkspace.shared.open(url)
                completion(nil)
            } else if let searchURL = URL(string: "https://www.google.com/search?q=\(cleaned.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                NSWorkspace.shared.open(searchURL)
                completion(nil)
            } else {
                completion("Invalid URL")
            }

        case .openInTextEdit:
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("ConCopy_QuickAction_\(UUID().uuidString).txt")
            do {
                try cleaned.write(to: tempFile, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(tempFile)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }

        case .runShellScript:
            if !skipConfirmation {
                let alert = NSAlert()
                alert.messageText = "Run Shell Command?"
                let displayCommand = cleaned.count > 120 ? String(cleaned.prefix(120)) + "..." : cleaned
                alert.informativeText = "ConCopy will execute the following command in /bin/zsh:\n\n\(displayCommand)\n\nAre you sure you want to run this?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Run")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()
                guard response == .alertFirstButtonReturn else {
                    completion("Command execution canceled")
                    return
                }
            }

            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", cleaned]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()

                    async let readDataTask = Task.detached(priority: .userInitiated) { () -> Data in
                        pipe.fileHandleForReading.readDataToEndOfFile()
                    }.value

                    // Enforce a 10-second timeout so long-running or hanging scripts terminate safely
                    let timeoutNanoseconds: UInt64 = 10_000_000_000
                    let startTime = DispatchTime.now()
                    while process.isRunning {
                        if DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds > timeoutNanoseconds {
                            process.terminate()
                            break
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }

                    process.waitUntilExit()
                    let outputData = await readDataTask
                    try? pipe.fileHandleForReading.close()

                    let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    await MainActor.run {
                        if process.terminationStatus == 0 {
                            completion(output.isEmpty ? "Command executed successfully" : output)
                        } else {
                            completion("Command failed (exit code \(process.terminationStatus))")
                        }
                    }
                } catch {
                    await MainActor.run {
                        completion(error.localizedDescription)
                    }
                }
            }

        case .shareSheet:
            let picker = NSSharingServicePicker(items: [cleaned])
            if let window = NSApp.keyWindow {
                picker.show(relativeTo: .zero, of: window.contentView ?? NSView(), preferredEdge: .minY)
                completion(nil)
            } else {
                completion("No active window for share sheet")
            }
        }
    }

    private static func escapeAppleScript(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    @MainActor
    private static func runAppleScript(_ script: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        var errorDict: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&errorDict)
            if let error = errorDict {
                completion(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error")
            } else {
                completion(nil)
            }
        } else {
            completion("Failed to initialize script")
        }
    }
}

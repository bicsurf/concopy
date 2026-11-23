import AppKit
import ConCopyCore
import SwiftUI

@MainActor
public final class UpdateDownloadController: ObservableObject {
    public static let shared = UpdateDownloadController()
    public var onReadyToInstall: (() -> Void)?
    @Published private(set) var version = ""
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDownloading = false
    private var window: NSWindow?
    private var task: Task<Void, Never>?

    public func start(_ update: AvailableUpdate) {
        showWindow()
        guard !isDownloading else { return }
        version = update.version
        received = 0
        expected = 0
        errorMessage = nil
        guard let url = update.dmgDownloadURL else {
            errorMessage = "This release does not include a disk image. Please try checking again later."
            return
        }
        isDownloading = true
        task = Task { [weak self] in
            do {
                let file = try await UpdateDownloader().download(from: url) { [weak self] bytes, total in
                    Task { @MainActor [weak self] in
                        self?.received = bytes
                        self?.expected = total
                    }
                }
                guard let self else { return }
                guard NSWorkspace.shared.open(file) else {
                    throw CocoaError(.fileReadUnknown)
                }
                self.isDownloading = false
                self.task = nil
                self.onReadyToInstall?()
            } catch {
                self?.isDownloading = false
                self?.errorMessage = error.localizedDescription
                self?.task = nil
            }
        }
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ConCopy Update"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UpdateDownloadView(controller: self))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }

    fileprivate func close() { window?.orderOut(nil) }
}

private struct UpdateDownloadView: View {
    @ObservedObject var controller: UpdateDownloadController
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Downloading update", systemImage: "arrow.down.circle.fill")
                .font(.title2.weight(.semibold))
            Text("New version: \(controller.version)").foregroundStyle(.secondary)
            if let error = controller.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Text("ConCopy will remain open. Use Download again to retry.").font(.callout)
            } else {
                if controller.expected > 0 {
                    let fraction = min(1, Double(controller.received) / Double(controller.expected))
                    ProgressView(value: fraction)
                    HStack {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                        Spacer()
                        Text("\(bytes(controller.received)) / \(bytes(controller.expected))")
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloaded \(bytes(controller.received))").font(.caption).foregroundStyle(.secondary)
                }
                Text("The download continues in the background. When complete, ConCopy will quit and open the disk image for installation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Close") { controller.close() }.frame(maxWidth: .infinity).keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

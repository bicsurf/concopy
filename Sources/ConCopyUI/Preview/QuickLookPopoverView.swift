import AppKit
import ConCopyCore
import SwiftUI

public struct QuickLookPopoverView: View {
    public let clip: ClipRecord
    public let databaseManager: DatabaseManager
    public let onClose: () -> Void

    @State private var imageData: Data?
    @State private var imageResolution: String = ""
    @State private var imageSizeKB: String = ""
    @State private var zoomScale: CGFloat = 1.0

    public init(
        clip: ClipRecord,
        databaseManager: DatabaseManager,
        onClose: @escaping () -> Void
    ) {
        self.clip = clip
        self.databaseManager = databaseManager
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundColor(.accentColor)
                Text(clip.customName ?? clip.primaryType.rawValue.capitalized)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Preview Content
            Group {
                switch clip.primaryType {
                case .image:
                    imagePreviewView
                case .url:
                    urlPreviewView
                case .file:
                    filePreviewView
                default:
                    textPreviewView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 640, minHeight: 320, idealHeight: 400, maxHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadImageDataIfNeeded()
        }
        .onChange(of: clip.id) { _, _ in
            imageData = nil
            imageResolution = ""
            imageSizeKB = ""
            zoomScale = 1.0
            loadImageDataIfNeeded()
        }
    }

    private var iconName: String {
        switch clip.primaryType {
        case .image: return "photo"
        case .url: return "link"
        case .file: return "doc"
        default: return "text.alignleft"
        }
    }

    // MARK: - Text Preview
    private var textPreviewView: some View {
        let text = clip.plainText ?? ""
        let chars = text.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        let lines = text.components(separatedBy: .newlines).count

        return VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }

            Divider()

            HStack {
                Text("\(chars) caratteri  •  \(words) parole  •  \(lines) righe")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Copiato: \(clip.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Image Preview
    private var imagePreviewView: some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                if let data = imageData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoomScale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                } else {
                    ProgressView("Caricamento immagine...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            HStack {
                Text("Risoluzione: \(imageResolution)  •  Dimensione: \(imageSizeKB)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Button(action: { zoomScale = max(0.5, zoomScale - 0.25) }) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    Button(action: { zoomScale = 1.0 }) {
                        Text("\(Int(zoomScale * 100))%")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    Button(action: { zoomScale = min(3.0, zoomScale + 0.25) }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - URL Preview
    private var urlPreviewView: some View {
        let text = clip.plainText ?? ""
        let url = URL(string: text)

        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)

            if let host = url?.host {
                Text(host)
                    .font(.title2.bold())
            }

            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let url {
                Button("Apri nel Browser") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - File Preview
    private var filePreviewView: some View {
        let text = clip.plainText ?? ""
        let fileURL = URL(string: text) ?? URL(fileURLWithPath: text)

        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)

            Text(fileURL.lastPathComponent)
                .font(.title3.bold())

            Text(fileURL.path)
                .font(.caption)
                .textSelection(.enabled)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Mostra nel Finder") {
                NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private func loadImageDataIfNeeded() {
        guard clip.primaryType == .image else { return }
        Task {
            do {
                let payloads = try databaseManager.fetchPayloads(forClipId: clip.id)
                if let payload = payloads.first(where: { $0.utiType == "public.png" || $0.utiType == "public.tiff" }) {
                    let data = try databaseManager.loadPayloadData(for: payload)
                    await MainActor.run {
                        self.imageData = data
                        let kb = Double(data.count) / 1024.0
                        self.imageSizeKB = String(format: "%.1f KB", kb)

                        if let rep = NSBitmapImageRep(data: data) {
                            self.imageResolution = "\(rep.pixelsWide) × \(rep.pixelsHigh)"
                        }
                    }
                }
            } catch {
                print("[ConCopy] Failed to load preview image: \(error)")
            }
        }
    }
}

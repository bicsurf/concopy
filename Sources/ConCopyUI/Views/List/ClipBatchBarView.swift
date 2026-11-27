import AppKit
import ConCopyCore
import SwiftUI

public struct ClipBatchBarView: View {
    @ObservedObject public var viewModel: ClipboardViewModel
    @ObservedObject public var settings: AppSettingsManager

    public init(viewModel: ClipboardViewModel, settings: AppSettingsManager) {
        self.viewModel = viewModel
        self.settings = settings
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("\(viewModel.selectedClipIds.count) selected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Deselect", action: viewModel.clearSelection)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Deselect all (Esc)")
                if settings.isDirectPasteEnabled && viewModel.selectedClipIds.count > 1 {
                    Menu {
                        Button("Paste into form fields") {
                            viewModel.pasteSelectedBatch(mode: .sequentialFormFields(delayMs: 60))
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 28, height: 24)
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("More batch actions")
                }
            }
            HStack(spacing: 8) {
                Button {
                    viewModel.addSelectedToPasteQueue()
                } label: {
                    Label("Add to Queue", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                if viewModel.selectedClipIds.count > 1 {
                    Picker("Join with", selection: $viewModel.batchSeparator) {
                        ForEach(BatchPasteSeparator.allCases, id: \.self) { separator in
                            Text(separator.displayName).tag(separator)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }
                Spacer(minLength: 4)
                Button(settings.isDirectPasteEnabled ? "Paste selected" : "Copy selected") {
                    viewModel.pasteSelected()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(ConCopyTheme.Surfaces.footerBackground)
    }
}

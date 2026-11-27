import AppKit
import ConCopyCore
import SwiftUI

public struct ClipContextMenu: View {
    @ObservedObject public var viewModel: ClipboardViewModel
    public let clip: ClipRecord

    public init(viewModel: ClipboardViewModel, clip: ClipRecord) {
        self.viewModel = viewModel
        self.clip = clip
    }

    public var body: some View {
        Button(action: {
            viewModel.copyClipToPasteboard(clip: clip)
        }) {
            Label("Copy to Clipboard", systemImage: "doc.on.doc")
        }

        Button(action: {
            viewModel.paste(clip: clip)
        }) {
            Label("Paste (Return)", systemImage: "arrow.right.doc.on.clipboard")
        }

        Button(action: {
            viewModel.paste(clip: clip, optionHeld: true)
        }) {
            Label("Paste as Plain Text (⌥Return)", systemImage: "text.alignleft")
        }

        Divider()

        Button(action: {
            if let index = viewModel.clips.firstIndex(where: { $0.id == clip.id }) {
                viewModel.selectedIndex = index
                viewModel.isQuickLookVisible = true
            }
        }) {
            Label("Quick Look (Space)", systemImage: "eye")
        }

        Button(action: {
            viewModel.editingClip = clip
        }) {
            Label("Edit Text...", systemImage: "pencil")
        }

        Divider()

        Button(clip.isFavorite ? "Remove from Favorites (⌘D)" : "Add to Favorites (★)") {
            viewModel.toggleFavorite(clip: clip)
        }

        Button {
            viewModel.movingClip = clip
        } label: {
            Label("Move to List... (⌘M)", systemImage: "folder")
        }

        if clip.plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            Button {
                viewModel.createSnippetFromClip(clip)
            } label: {
                Label("Save as Snippet...", systemImage: "curlybraces")
            }

            Button {
                viewModel.addToPasteQueue(clip: clip)
            } label: {
                Label("Add to Paste Queue", systemImage: "rectangle.stack.badge.plus")
            }

            if let color = ColorParser.parse(clip.plainText ?? "") {
                Menu("Copy Color As") {
                    Button("HEX (\(color.hexString))") {
                        viewModel.copyPlainText(color.hexString)
                    }
                    Button("RGB (\(color.rgbString))") {
                        viewModel.copyPlainText(color.rgbString)
                    }
                    Button("HSL (\(color.hslString))") {
                        viewModel.copyPlainText(color.hslString)
                    }
                }
            }

            Menu("Paste Transformed") {
                ForEach(TextTransformation.allCases.filter { $0 != .none }, id: \.self) { transformation in
                    Button(transformation.displayName) {
                        viewModel.paste(clip: clip, transformation: transformation)
                    }
                }
            }

            Menu("Copy Transformed") {
                ForEach(TextTransformation.allCases.filter { $0 != .none }, id: \.self) { transformation in
                    Button(transformation.displayName) {
                        viewModel.copyClipToPasteboard(clip: clip, transformation: transformation)
                    }
                }
            }
        }

        if clip.primaryType == .image,
           let text = clip.plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            Button {
                viewModel.copyPlainText(text)
            } label: {
                Label("Copy Text from Image", systemImage: "text.viewfinder")
            }
        }

        Menu("Paste as File") {
            Button("Text File (.txt)") {
                viewModel.pasteAsFile(clip: clip)
            }
            if clip.primaryType == .image {
                Button("PNG Image (.png)") {
                    viewModel.pasteAsFile(clip: clip, imageFormat: .png)
                }
                Button("JPEG Image (.jpg)") {
                    viewModel.pasteAsFile(clip: clip, imageFormat: .jpeg)
                }
            }
        }

        if let text = clip.plainText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Menu("Quick Actions") {
                ForEach(QuickActionType.allCases, id: \.self) { action in
                    if QuickActionRunner.canExecute(action, for: clip) {
                        Button {
                            QuickActionRunner.execute(action, text: text) { feedback in
                                if let feedback {
                                    viewModel.showToast(feedback)
                                }
                            }
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
            }
        }

        Divider()

        Button("Delete (⌫)", role: .destructive) {
            viewModel.deleteClip(clip)
        }
    }
}

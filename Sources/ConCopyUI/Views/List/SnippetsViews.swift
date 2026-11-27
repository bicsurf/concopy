import AppKit
import ConCopyCore
import SwiftUI

public struct SnippetEditorSheetView: View {
    public let snippet: SnippetRecord?
    public var errorMessage: String? = nil
    public let onSave: (String, String, String?) -> Void
    public let onCancel: () -> Void

    @State private var shortcut: String = ""
    @State private var content: String = ""
    @State private var title: String = ""

    public init(
        snippet: SnippetRecord?,
        errorMessage: String? = nil,
        onSave: @escaping (String, String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snippet = snippet
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet == nil ? "New Snippet" : "Edit Snippet")
                .font(.headline)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }

            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcut (e.g. ;email or :sign)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(";shortcut", text: $shortcut)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label / Title (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. Personal Email", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Text Content (supports {date}, {time}, {clipboard}, {uuid}, or {name})")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $content)
                    .font(.system(size: 12))
                    .frame(height: 100)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(shortcut, content, title.isEmpty ? nil : title)
                }
                .disabled(shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 320)
        .onAppear {
            if let s = snippet {
                shortcut = s.shortcut
                content = s.content
                title = s.title ?? ""
            }
        }
    }
}

public struct SnippetVariablesPromptSheetView: View {
    public let snippet: SnippetRecord
    public let variableNames: [String]
    public let onFill: ([String: String]) -> Void
    public let onCancel: () -> Void

    @State private var values: [String: String] = [:]

    public init(
        snippet: SnippetRecord,
        variableNames: [String],
        onFill: @escaping ([String: String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snippet = snippet
        self.variableNames = variableNames
        self.onFill = onFill
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Fill Snippet Variables", systemImage: "text.cursor")
                    .font(.headline)
                Spacer()
            }

            Text("Enter values for variables defined in '\(snippet.title ?? snippet.shortcut)':")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(variableNames, id: \.self) { variable in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("{\(variable)}")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ConCopyTheme.Accents.primary)
                            TextField("Value for \(variable)...", text: Binding(
                                get: { values[variable] ?? "" },
                                set: { values[variable] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 200)

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Paste Snippet") {
                    onFill(values)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 320, idealWidth: 360)
        .onAppear {
            for v in variableNames {
                values[v] = ""
            }
        }
    }
}

public struct SnippetRowView: View {
    public let snippet: SnippetRecord
    public let isSelected: Bool
    public var onRowClick: (() -> Void)? = nil
    public var onEdit: (() -> Void)? = nil
    public var onDelete: (() -> Void)? = nil

    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        snippet: SnippetRecord,
        isSelected: Bool,
        onRowClick: (() -> Void)? = nil,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.snippet = snippet
        self.isSelected = isSelected
        self.onRowClick = onRowClick
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    public var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ConCopyTheme.Types.background(for: .text))
                    .frame(width: 24, height: 24)
                Image(systemName: "curlybraces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ConCopyTheme.Types.foreground(for: .text))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snippet.shortcut)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(ConCopyTheme.Accents.primary)

                    if let title = snippet.title, !title.isEmpty {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(snippet.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !SnippetVariableResolver.extractCustomVariables(from: snippet.content).isEmpty
                || snippet.content.contains("{date}")
                || snippet.content.contains("{time}")
                || snippet.content.contains("{datetime}")
                || snippet.content.contains("{uuid}")
                || snippet.content.contains("{clipboard}") {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11))
                    .foregroundStyle(ConCopyTheme.Accents.primary)
                    .help("Dynamic template snippet")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onRowClick?()
        }
        .background(
            isSelected
                ? ConCopyTheme.Rows.selectedBackground
                : (isHovered ? ConCopyTheme.Rows.hoverBackground : Color.clear),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    isSelected
                        ? (contrast == .increased ? Color.primary : ConCopyTheme.Rows.selectedBorder) : Color.clear,
                    lineWidth: contrast == .increased ? 2 : 1)
        }
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Edit Snippet...") {
                onEdit?()
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete?()
            }
        }
    }
}

public struct SnippetsListView: View {
    @ObservedObject public var viewModel: ClipboardViewModel
    @FocusState.Binding public var isFieldFocused: Bool

    public init(viewModel: ClipboardViewModel, isFieldFocused: FocusState<Bool>.Binding) {
        self.viewModel = viewModel
        self._isFieldFocused = isFieldFocused
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Snippets Subheader / Actions
            HStack(spacing: 8) {
                Text("\(viewModel.filteredSnippets.count) snippet(s)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    viewModel.editingSnippet = SnippetRecord(
                        shortcut: ";",
                        content: "",
                        title: ""
                    )
                    viewModel.isSnippetEditorPresented = true
                } label: {
                    Label("New Snippet", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider().opacity(0.2)

            if viewModel.filteredSnippets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No Snippets Found")
                        .font(.headline)
                    Text(
                        viewModel.searchQuery.isEmpty
                            ? "Create reusable text snippets with shortcuts like ;email or ;addr"
                            : "No snippets match '\(viewModel.searchQuery)'"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                    if !viewModel.searchQuery.isEmpty {
                        Button("Clear Search") {
                            viewModel.searchQuery = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(viewModel.filteredSnippets.enumerated()), id: \.element.id) { index, snippet in
                                SnippetRowView(
                                    snippet: snippet,
                                    isSelected: viewModel.selectedSnippetIndex == index,
                                    onRowClick: {
                                        viewModel.selectedSnippetIndex = index
                                        viewModel.pasteSnippet(snippet)
                                    },
                                    onEdit: {
                                        viewModel.editingSnippet = snippet
                                        viewModel.isSnippetEditorPresented = true
                                    },
                                    onDelete: {
                                        viewModel.deleteSnippet(snippet)
                                    }
                                )
                                .id(snippet.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: viewModel.selectedSnippetIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < viewModel.filteredSnippets.count {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(viewModel.filteredSnippets[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
}

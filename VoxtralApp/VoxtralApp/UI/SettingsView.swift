import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var configStore:    ConfigStore
    @EnvironmentObject private var dictionaryStore: DictionaryStore

    var body: some View {
        TabView {
            GeneralTab()
                .environmentObject(configStore)
                .tabItem { Label("General", systemImage: "gear") }

            DictionaryTab()
                .environmentObject(dictionaryStore)
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @EnvironmentObject private var configStore: ConfigStore

    var body: some View {
        Form {
            Section("Input") {
                Picker("Hotkey", selection: hotkeyBinding) {
                    Text("fn  (Globe)").tag("fn")
                    Text("Right Option  ⌥").tag("rightOption")
                    Text("Right Command  ⌘").tag("rightCommand")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var hotkeyBinding: Binding<String> {
        Binding(
            get: { configStore.config.hotkey },
            set: { v in configStore.update { $0.hotkey = v } }
        )
    }
}

// MARK: - Dictionary tab

private struct DictionaryTab: View {
    @EnvironmentObject private var dictionaryStore: DictionaryStore
    @State private var editorConfig: EditorConfig?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(dictionaryStore.entries) { entry in
                    DictionaryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editorConfig = EditorConfig(entry: entry, isNew: false)
                        }
                }
                .onDelete { dictionaryStore.remove(at: $0) }
            }

            Divider()

            HStack {
                Text("\(dictionaryStore.entries.count) term\(dictionaryStore.entries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editorConfig = EditorConfig(
                        entry: DictionaryEntry(canonical: "", variants: []),
                        isNew: true
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(item: $editorConfig) { config in
            EntryEditorView(config: config) { saved in
                if config.isNew {
                    dictionaryStore.add(saved)
                } else {
                    dictionaryStore.update(saved)
                }
            }
        }
    }
}

// MARK: - Dictionary row

private struct DictionaryRow: View {
    let entry: DictionaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.canonical)
                .font(.body)
            if !entry.variants.isEmpty {
                Text(entry.variants.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor sheet config

// Identifiable so .sheet(item:) recreates the sheet for each distinct config.
private struct EditorConfig: Identifiable {
    let id = UUID()
    var entry: DictionaryEntry
    let isNew: Bool
}

// MARK: - Entry editor view

private struct EntryEditorView: View {
    @State private var canonical:    String
    @State private var variantsText: String  // comma-separated; split on save
    private let entryID: UUID
    private let onSave: (DictionaryEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    init(config: EditorConfig, onSave: @escaping (DictionaryEntry) -> Void) {
        _canonical    = State(initialValue: config.entry.canonical)
        _variantsText = State(initialValue: config.entry.variants.joined(separator: ", "))
        entryID       = config.entry.id
        self.onSave   = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictionary Term")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                TextField("Term  (e.g. SFCC)", text: $canonical)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                TextField("Variants, comma-separated  (e.g. sfcc, SFCC)", text: $variantsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }

            Text("Variants are replaced live during dictation (Layer 2). At least one variant is required for an entry to take effect.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(canonical.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save() {
        let variants = variantsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(DictionaryEntry(
            id: entryID,
            canonical: canonical.trimmingCharacters(in: .whitespaces),
            variants: variants
        ))
        dismiss()
    }
}

import Foundation
import Combine

// Single source of truth for dictionary data.
// Layer 2 (variant→canonical substitution) is owned HERE and applied in STTClient.
// Layer 3 (canonical list for LLM prompt) is exposed via canonicalNames.
// NO dictionary state exists in the sidecar.
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []

    private(set) var layer2Map: [String: String] = [:]  // variant → canonical
    var canonicalNames: [String] { entries.map(\.canonical) }

    private weak var configStore: ConfigStore?

    init(configStore: ConfigStore) {
        self.configStore = configStore
        entries = configStore.config.dictionary
        buildLayer2Map()
    }

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        buildLayer2Map()
        persist()
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        buildLayer2Map()
        persist()
    }

    func update(_ entry: DictionaryEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        buildLayer2Map()
        persist()
    }

    // MARK: - Private

    private func buildLayer2Map() {
        // Flat-map: each variant of each entry maps to its canonical term.
        // Entries with no variants add nothing here but still appear in canonicalNames (Layer 3).
        var map: [String: String] = [:]
        for entry in entries {
            for variant in entry.variants {
                map[variant] = entry.canonical
            }
        }
        layer2Map = map
    }

    private func persist() {
        // Route dictionary changes back through ConfigStore so they hit disk and
        // fire @Published config for any other observers in one call.
        // weak ref: no-op if ConfigStore was deallocated (shouldn't happen in normal lifecycle).
        configStore?.update { $0.dictionary = entries }
    }
}

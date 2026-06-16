import Foundation

struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var canonical: String   // authoritative domain term
    var variants: [String]  // known misspellings to fix deterministically (Layer 2)

    init(id: UUID = UUID(), canonical: String, variants: [String] = []) {
        self.id = id
        self.canonical = canonical
        self.variants = variants
    }
}
